<?php

// Export synthetic fixtures through the actual API serializers. No database writes or sends.
$root = $argv[1] ?? throw new InvalidArgumentException('Pass the Laravel directory.');
require $root.'/vendor/autoload.php';
$app = require $root.'/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
Carbon\Carbon::setTestNow('2026-09-07T12:00:00Z');
Carbon\CarbonImmutable::setTestNow('2026-09-07T12:00:00Z');

function syntheticValue(?ReflectionType $type, int $depth = 0): mixed
{
    if ($type === null) {
        return null;
    }
    if ($type instanceof ReflectionUnionType) {
        foreach ($type->getTypes() as $option) {
            if ($option->getName() === Spatie\LaravelData\Optional::class) {
                return Spatie\LaravelData\Optional::create();
            }
        }
        foreach ($type->getTypes() as $option) {
            if ($option->getName() !== 'null') {
                return syntheticValue($option, $depth);
            }
        }
    }
    $name = $type->getName();
    if ($type->isBuiltin()) {
        return match ($name) {
            'string' => 'fixture-value', 'int' => 1, 'float' => 1.25,
            'bool' => true, 'array' => [], default => null,
        };
    }
    if (is_a($name, Carbon\CarbonInterface::class, true)) {
        return Carbon\CarbonImmutable::parse('2026-09-07T12:00:00Z');
    }
    if (enum_exists($name)) {
        return $name::cases()[0];
    }
    if ($type->allowsNull()) {
        return null;
    }
    if ($depth > 5) {
        throw new RuntimeException('Recursive fixture type: '.$name);
    }
    return syntheticData($name, $depth + 1);
}

function syntheticData(string $class, int $depth = 0): object
{
    $reflection = new ReflectionClass($class);
    $arguments = [];
    foreach ($reflection->getConstructor()?->getParameters() ?? [] as $parameter) {
        $arguments[] = $parameter->isDefaultValueAvailable()
            ? $parameter->getDefaultValue()
            : syntheticValue($parameter->getType(), $depth);
    }
    return $reflection->newInstanceArgs($arguments);
}

$spec = json_decode(file_get_contents(__DIR__.'/../specs/team-openapi.json'), true, flags: JSON_THROW_ON_ERROR);
$fixtures = ['models' => [], 'enums' => [], 'routes' => []];
foreach ($app['router']->getRoutes() as $route) {
    if (! str_starts_with($route->getActionName(), 'App\\Http\\Controllers\\Api\\V1\\')) {
        continue;
    }
    $controller = substr($route->getActionName(), strlen('App\\Http\\Controllers\\Api\\V1\\'));
    if (! str_starts_with($route->uri(), 'v1/') || str_contains($controller, '\\')) {
        continue;
    }
    if (in_array('api.credentials:oauth', $route->gatherMiddleware(), true)) {
        continue;
    }
    foreach (array_diff($route->methods(), ['HEAD']) as $method) {
        $fixtures['routes'][] = ['method' => $method, 'path' => '/'.substr($route->uri(), 3)];
    }
}
$files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root.'/app/Data/Api/V1'));
foreach ($files as $file) {
    if ($file->getExtension() !== 'php') {
        continue;
    }
    $name = $file->getBasename('.php');
    if (! isset($spec['components']['schemas'][$name]) || str_starts_with($name, 'Store') || str_starts_with($name, 'Update') || $name === 'StatsRequestData') {
        continue;
    }
    $class = 'App\\'.str_replace('/', '\\', substr($file->getPathname(), strlen($root.'/app/'), -4));
    $data = syntheticData($class);
    if ($data instanceof App\Data\Api\V1\Team\TeamMemberData) {
        $data->role = ['id' => 'role-id', 'name' => 'Member'];
    }
    if ($data instanceof App\Data\Api\V1\Suppression\SuppressedRecipientData) {
        $data->scope = App\Enums\SuppressionScope::Team;
    }
    $fixtures['models'][$name] = $data->toArray();
}
foreach ($spec['components']['schemas'] as $name => $schema) {
    $class = 'App\\Enums\\'.$name;
    if (isset($schema['enum']) && enum_exists($class)) {
        $cases = method_exists($class, 'apiCases') ? $class::apiCases() : $class::cases();
        $values = array_column($cases, 'value');
        // Disposable-email entries belong to the global suppression list, outside this API.
        if ($name === 'SuppressionReason') {
            $values = array_values(array_diff($values, ['disposable_email']));
        }
        $fixtures['enums'][$name] = $values;
    }
}

$fixtures['pages'] = [];
foreach ([
    'MessageIndexResponse' => App\Data\Api\V1\Message\MessageListData::class,
    'MessageEventsResponse' => App\Data\Api\V1\Message\MessageEventData::class,
    'DomainIndexResponse' => App\Data\Api\V1\Domain\DomainListData::class,
    'ProjectIndexResponse' => App\Data\Api\V1\Project\ProjectListData::class,
    'RouteIndexResponse' => App\Data\Api\V1\Route\RouteListData::class,
    'SuppressionIndexResponse' => App\Data\Api\V1\Suppression\SuppressedRecipientData::class,
    'WebhookIndexResponse' => App\Data\Api\V1\Webhook\WebhookListData::class,
    'WebhookDeliveriesResponse' => App\Data\Api\V1\Webhook\WebhookDeliveryListData::class,
] as $responseName => $class) {
    $data = syntheticData($class);
    if ($data instanceof App\Data\Api\V1\Suppression\SuppressedRecipientData) {
        $data->scope = App\Enums\SuppressionScope::Team;
    }
    $paginator = new Illuminate\Pagination\CursorPaginator([$data, clone $data], 1, null,
        ['path' => 'https://api.lettermint.co/v1/fixture', 'parameters' => [property_exists($data, 'id') ? 'id' : 'message_id']]);
    $result = $class::collect($paginator);
    $fixtures['pages'][$responseName] = json_decode(response()->json($result)->getContent(), true, flags: JSON_THROW_ON_ERROR);
}

$route = syntheticData(App\Data\Api\V1\Route\RouteData::class);
$route->settings = ['attachment_delivery' => 'url', 'tls' => 'enforced', 'track_opens' => false];
$route->statistics = [];
$fixtures['route_settings'] = $route->toArray();

$mail = (new ReflectionClass(App\Data\MailerData::class))->newInstanceWithoutConstructor();
$mail->messageId = '00000000-0000-4000-8000-000000000001';
foreach (['SendMailController', 'SendBatchMailController'] as $controllerName) {
    $reflection = new ReflectionClass('App\\Http\\Controllers\\Api\\V1\\'.$controllerName);
    $controller = $reflection->newInstanceWithoutConstructor();
    $method = $reflection->getMethod('responseData');
    $mail->scheduledAt = null;
    $fixtures[$controllerName]['immediate'] = $method->invoke($controller, $mail);
    $mail->scheduledAt = Carbon\CarbonImmutable::parse('2026-09-08T12:00:00Z');
    $fixtures[$controllerName]['scheduled'] = $method->invoke($controller, $mail);
}

$fixtures['suppression_removed'] = App\Services\SuppressionRemoval\SuppressionRemovalResult::removed()->toResponseData();
$assessment = new App\Services\SuppressionRemoval\SuppressionRemovalAssessment(
    decision: App\Services\SuppressionRemoval\SuppressionRemovalDecision::cases()[0],
    confidence: 0.75,
    rationale: 'Synthetic contract fixture.',
);
$fixtures['suppression_review'] = App\Services\SuppressionRemoval\SuppressionRemovalResult::reviewTicketCreated($assessment, 'SUP-123')->toResponseData();

$service = (new ReflectionClass(App\Services\WebhookService::class))->newInstanceWithoutConstructor();
$fixtures['webhook_signature'] = $service->generateSignature(['url' => 'https://example.com/path', 'name' => 'Café'], 'fixture-signing-secret');
$fixtures['request_rules'] = [
    'single' => array_keys((new App\Http\Requests\Api\V1\SendMailRequest)->rules()),
    'batch' => array_keys((new App\Http\Requests\Api\V1\SendBatchMailRequest)->rules()),
];
echo json_encode($fixtures, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR).PHP_EOL;
