#!/usr/bin/env python3
"""Generate Elixir models and endpoints from the two API specifications."""
import argparse
import copy
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def name(value):
    result = ''.join(p[:1].upper() + p[1:] for p in re.split(r'[^a-zA-Z0-9]', value) if p)
    return ('Value' + result) if result[:1].isdigit() else result

class Generator:
    def __init__(self, specs):
        self.specs = copy.deepcopy(specs)
        # Both FormRequest classes validate string-valued header and metadata maps.
        if 'sending' in self.specs:
            schemas = self.specs['sending']['components']['schemas']
            for payload in [schemas['SendMailRequest'], schemas['SendBatchMailRequest']['items']]:
                for field in ['headers', 'metadata']:
                    payload['properties'][field] = {'type': 'object', 'additionalProperties': {'type': 'string'}}
        # RouteData.php declares a serialized AttachmentDelivery enum value.
        if 'team' in self.specs:
            settings = self.specs['team']['components']['schemas'].get('RouteData', {}).get('properties', {}).get('settings', {})
            if 'attachment_delivery' in settings.get('properties', {}):
                settings['properties']['attachment_delivery'] = {'$ref': '#/components/schemas/AttachmentDelivery'}
        # MessageController returns a Laravel CursorPaginator through Data::collect.
        # Scramble's CursorPaginatedDataCollection annotation describes a different envelope.
        if 'team' in self.specs:
            team = self.specs['team']
            page_template = team['paths']['/domains']['get']['responses']['200']['content']['application/json']['schema']
            for path, model in [('/messages', 'MessageListData'), ('/messages/{messageId}/events', 'MessageEventData')]:
                page = copy.deepcopy(page_template)
                page['properties']['data']['items'] = {'$ref': '#/components/schemas/' + model}
                team['paths'][path]['get']['responses']['200']['content']['application/json']['schema'] = page
        specs = self.specs
        self.schemas = {}
        self.definitions = {}
        for spec in specs.values():
            for key, schema in spec['components']['schemas'].items():
                if key in self.schemas and self.schemas[key] != schema:
                    raise ValueError('Conflicting schema: ' + key)
                self.schemas[key] = schema

    def type(self, schema, hint):
        if not schema or schema is True:
            return ':any'
        if '$ref' in schema:
            key = schema['$ref'].split('/')[-1]
            return self.type(self.schemas[key], key)
        choices = schema.get('anyOf', schema.get('oneOf'))
        if choices:
            choices = [v for v in choices if v.get('type') != 'null']
            if len(choices) == 1:
                return self.type(choices[0], hint)
            if all(v.get('type') == 'object' for v in choices):
                props = {}
                for v in choices:
                    for k, value in v.get('properties', {}).items():
                        if k in props and props[k] != value:
                            if props[k].get('type') == value.get('type') == 'string':
                                value = {'type': 'string'}
                            else:
                                raise ValueError('Conflicting union property: ' + k)
                        props[k] = value
                return self.type({'type': 'object', 'properties': props}, hint)
            return '{:union, [' + ', '.join(self.type(v, hint + str(i)) for i,v in enumerate(choices)) + ']}'
        kind = schema.get('type', 'object')
        if isinstance(kind, list):
            kind = next(k for k in kind if k != 'null')
        if schema.get('enum'):
            self.definitions[hint] = '\n'.join([f'defmodule Lettermint.Models.{hint} do', '  @moduledoc "API enum values. Unknown response values remain strings."', '  @type t :: String.t()', '  def values, do: ' + json.dumps(schema['enum']), 'end\n'])
            return ':string'
        if kind == 'array':
            return '{:list, ' + self.type(schema.get('items', {}), hint + 'Item') + '}'
        if schema.get('properties'):
            if hint not in self.definitions:
                self.definitions[hint] = ''
                fields = [(p, self.type(v, hint + name(p))) for p,v in schema['properties'].items()]
                self.definitions[hint] = '\n'.join([
                    f'defmodule Lettermint.Models.{hint} do',
                    '  @moduledoc "Generated API model. `:unset` fields are omitted from requests."',
                    '  defstruct ' + ', '.join(f'{p}: :unset' for p,_ in fields) + ', extra: %{}',
                    '  @type t :: %__MODULE__{' + ', '.join(f'{p}: {self.typespec(t)} | nil | :unset' for p,t in fields) + ', extra: map()}',
                    '  def __schema__, do: [' + ', '.join(f'{{{json.dumps(p)}, :{p}, {t}}}' for p,t in fields) + ']',
                    'end\n'])
            return f'{{:model, Lettermint.Models.{hint}}}'
        if kind == 'object':
            return '{:map, ' + self.type(schema.get('additionalProperties', {}), hint + 'Value') + '}'
        return ':' + {'integer':'integer','number':'number','boolean':'boolean','string':'string','null':'any'}[kind]

    def typespec(self, descriptor):
        if descriptor.startswith('{:model, '): return descriptor[9:-1] + '.t()'
        if descriptor.startswith('{:list, '): return '[' + self.typespec(descriptor[8:-1]) + ']'
        if descriptor.startswith('{:map, '): return '%{optional(String.t()) => ' + self.typespec(descriptor[7:-1]) + '}'
        return {':string':'String.t()', ':integer':'integer()', ':number':'number()', ':boolean':'boolean()'}.get(descriptor, 'term()')

    def generate(self):
        for key, schema in self.schemas.items(): self.type(schema, key)
        groups, manifest = {}, []
        mapping = {'index':'list','store':'create','show':'retrieve','destroy':'delete','verifySpecificDnsRecord':'verify_dns_record','members.show':'retrieve_member','members.assignment.update':'update_member_assignment'}
        for surface, spec in self.specs.items():
            for path, item in spec['paths'].items():
                for verb, op in item.items():
                    if verb not in ['get','post','put','patch','delete']: continue
                    operation = op['operationId']
                    prefix, action = operation.split('.', 1) if '.' in operation else {'rescheduleMessage':('message','reschedule'),'cancelScheduledMessage':('message','cancel'),'processInboundMessage':('message','process')}[operation]
                    group = 'Email' if surface == 'sending' else ('API' if prefix == 'v1' else name({'domain':'domains','message':'messages','project':'projects','route':'routes','suppression':'suppressions','webhook':'webhooks'}.get(prefix,prefix)))
                    method = mapping.get(action, snake(action))
                    if prefix == 'stats': method = 'retrieve'
                    if surface == 'sending': method = {'sendMail':'send','sendBatchMail':'send_batch','ping':'ping'}[action]
                    params = [p['name'] for p in item.get('parameters',[]) + op.get('parameters',[]) if p['in']=='path']
                    payload = op.get('requestBody',{}).get('content',{}).get('application/json',{}).get('schema')
                    request = self.type(payload,name(operation)+'Request') if payload else None
                    responses = [v for k,v in op['responses'].items() if k.startswith('2')]
                    content = responses[0].get('content',{})
                    raw = action == 'ping' or (bool(content) and 'application/json' not in content)
                    variants = [r.get('content',{}).get('application/json',{}).get('schema') for r in responses]
                    variants = [v for v in variants if v]
                    schema = variants[0] if len(variants)==1 else {'anyOf':variants} if variants else {}
                    response = ':ping' if action=='ping' else ':raw' if raw else self.type(schema,{'v1.sendMail':'SendEmailResponse','v1.sendBatchMail':'SendBatchEmailResponse'}.get(operation,name(operation)+'Response'))
                    args = ['client'] + [snake(p) for p in params] + (['payload'] if payload else [])
                    route = re.sub(r'\{([^}]+)\}',lambda m: '#{Lettermint.Transport.segment('+snake(m[1])+')}',path)
                    scope = ':either' if operation in ['rescheduleMessage','cancelScheduledMessage'] else ':'+surface
                    arg_types = ['Lettermint.Client.t()'] + ['String.t()'] * len(params) + ([self.typespec(request) + ' | map() | list()'] if payload else []) + ['keyword()']
                    signature = f'  @spec {method}({", ".join(arg_types)}) :: {{:ok, {"String.t()" if raw else self.typespec(response)} | nil}} | {{:error, Lettermint.Error.t()}}\n'
                    code = signature + f'  @doc "Call `{verb.upper()} {path}`. Use `query`, `headers`, or `idempotency_key` in options."\n  def {method}({", ".join(args)}, opts \\\\ []) do\n    Lettermint.Transport.request(client, {scope}, :{verb}, "{route}", {"payload" if payload else ":unset"}, {response}, opts)\n  end\n'
                    groups.setdefault(group,[]).append(code)
                    manifest.append(dict(surface=surface,operationId=operation,module='Lettermint.'+group,method=method,verb=verb.upper(),path=path,params=params,payload=bool(payload),request=request,response=response))
        source = '# Generated by tools/generate.py. Do not edit.\n\n' + '\n'.join(self.definitions[k] for k in sorted(self.definitions))
        for group, methods in groups.items():
            source += f'\ndefmodule Lettermint.{group} do\n  @moduledoc "{group} API operations. Each call returns an ok or error tuple."\n'
            if group == 'Email': source += '  import Kernel, except: [send: 2]\n'
            source += '\n'.join(methods) + 'end\n'
        source = subprocess.run(['elixir', '-e', 'IO.read(:stdio, :eof) |> Code.format_string!() |> IO.iodata_to_binary() |> IO.write()'], input=source, text=True, capture_output=True, check=True).stdout + '\n'
        return {'lib/lettermint/generated.ex':source,'specs/operations.json':json.dumps(manifest,indent=2)+'\n'}

def snake(value):
    return re.sub(r'(?<!^)(?=[A-Z])','_',value).replace('.','_').lower()

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--check',action='store_true')
    parser.add_argument('--spec-dir',type=Path,default=ROOT/'specs')
    args=parser.parse_args()
    specs={k:json.loads((args.spec_dir/(k+'-openapi.json')).read_text()) for k in ['sending','team']}
    for relative, content in Generator(specs).generate().items():
        target=ROOT/relative
        if args.check:
            if not target.exists() or target.read_text()!=content:raise SystemExit('Generated file differs: '+relative)
        else:target.write_text(content)

if __name__=='__main__':main()
