"""Test generator behavior without a stored API specification."""
import copy
import json
import subprocess
import sys
import unittest
from generate import Generator, ROOT


class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.specs = {'example': {
            'components': {'schemas': {'Status': {'type': 'string', 'enum': ['hard_bounced']}}},
            'paths': {'/examples/{exampleId}': {'get': {
                'operationId': 'domain.show',
                'parameters': [{'name': 'exampleId', 'in': 'path'}],
                'responses': {
                    '200': {'content': {'application/json': {'schema': {'type': 'object', 'properties': {'id': {'type': 'string'}}}}}},
                    '202': {'content': {'application/json': {'schema': {'type': 'object', 'properties': {'ticket': {'type': 'string'}}}}}},
                },
            }}},
        }}

    def test_deterministic_without_input_mutation(self):
        before = copy.deepcopy(self.specs)
        self.assertEqual(Generator(self.specs).generate(), Generator(self.specs).generate())
        self.assertEqual(self.specs, before)

    def test_operation_mapping_and_response_variants(self):
        files = Generator(self.specs).generate()
        operation, = json.loads(files['specs/operations.json'])
        self.assertEqual((operation['surface'], operation['verb'], operation['path']),
                         ('example', 'GET', '/examples/{exampleId}'))
        self.assertIn('Lettermint.Transport.segment(example_id)', files['lib/lettermint/generated.ex'])
        self.assertIn('ticket:', files['lib/lettermint/generated.ex'])

    def test_nullable_union_and_map(self):
        generator = Generator({})
        self.assertEqual(generator.type({'anyOf': [{'type': 'null'}, {'type': 'string'}]}, 'Value'), ':string')
        self.assertEqual(generator.type({'oneOf': [{'type': 'array', 'items': {'type': 'integer'}}, {'type': 'string'}]}, 'Value'), '{:union, [{:list, :integer}, :string]}')
        self.assertEqual(generator.type({'type': 'object', 'additionalProperties': {'type': 'string'}}, 'Headers'), '{:map, :string}')

    def test_conflicting_schemas_fail(self):
        self.specs['other'] = {'components': {'schemas': {'Status': {'type': 'integer'}}}}
        with self.assertRaises(ValueError):
            Generator(self.specs)

    def test_stored_manifest_matches_source_route_fixtures(self):
        fixture = json.loads((ROOT/'test/fixtures/api-source.json').read_text())
        operations = json.loads((ROOT/'specs/operations.json').read_text())
        self.assertEqual({(r['method'], r['path']) for r in fixture['routes']},
                         {(r['verb'], r['path']) for r in operations})

    def test_external_spec_directory_is_required(self):
        result = subprocess.run([sys.executable, str(ROOT/'tools/generate.py'), '--check'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('--spec-dir', result.stderr)
        for surface in ['sending', 'team']:
            self.assertFalse((ROOT/'specs'/f'{surface}-openapi.json').exists())
