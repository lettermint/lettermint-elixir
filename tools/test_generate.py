import copy
import json
import unittest
from pathlib import Path
from generate import Generator
ROOT = Path(__file__).resolve().parents[1]

class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.specs = {k: json.loads((ROOT/'specs'/f'{k}-openapi.json').read_text()) for k in ['sending', 'team']}

    def test_deterministic_without_input_mutation(self):
        before = copy.deepcopy(self.specs)
        self.assertEqual(Generator(self.specs).generate(), Generator(self.specs).generate())
        self.assertEqual(before, self.specs)

    def test_independent_spec_inputs(self):
        for surface, spec in self.specs.items():
            files = Generator({surface: spec}).generate()
            operations = json.loads(files['specs/operations.json'])
            self.assertTrue(all(op['surface'] == surface for op in operations))

    def test_all_success_responses_are_merged(self):
        source = Generator(self.specs).generate()['lib/lettermint/generated.ex']
        response = source.split('defmodule Lettermint.Models.SuppressionDestroyResponse do')[1].split('\nend')[0]
        self.assertIn('ticket_identifier:', response)
        self.assertIn('confidence:', response)

    def test_request_rules_match_generated_models(self):
        generator = Generator(self.specs)
        fixtures = json.loads((ROOT/'test/fixtures/api-source.json').read_text())
        schemas = generator.specs['sending']['components']['schemas']
        def walk(schema):
            result = set()
            if '$ref' in schema:
                return walk(generator.schemas[schema['$ref'].split('/')[-1]])
            for key, value in schema.get('properties', {}).items():
                result.add(key)
                result.update(key+'.'+p for p in walk(value))
            if schema.get('type') == 'array':
                result.add('*')
                result.update('*.'+p for p in walk(schema.get('items', {})))
            if schema.get('additionalProperties'):
                result.add('*')
            return result
        for kind, key in [('single','SendMailRequest'),('batch','SendBatchMailRequest')]:
            self.assertTrue(set(fixtures['request_rules'][kind]) <= walk(schemas[key]))

    def test_nullable_and_mixed_union_types(self):
        g = Generator({})
        self.assertEqual(g.type({'anyOf':[{'type':'null'},{'type':'string'}]}, 'Test'), ':string')
        self.assertEqual(g.type({'oneOf':[{'type':'array','items':{'type':'integer'}},{'type':'string'}]}, 'Test'), '{:union, [{:list, :integer}, :string]}')

    def test_conflicting_named_schemas_fail(self):
        specs = {'a':{'components':{'schemas':{'Test':{'type':'string'}}}}, 'b':{'components':{'schemas':{'Test':{'type':'integer'}}}}}
        with self.assertRaises(ValueError): Generator(specs)

if __name__ == '__main__': unittest.main()
