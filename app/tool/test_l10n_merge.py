"""Offline regression tests: python3 -m unittest discover -s app/tool -p test_l10n_merge.py."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import l10n_merge


class MessagePreflightTest(unittest.TestCase):
    def test_duplicate_plural_and_select_cases_are_rejected(self):
        for kind, case in [('plural', 'one'), ('plural', '=1'), ('select', 'ready')]:
            with self.subTest(kind=kind, case=case):
                _, errors = l10n_merge.parse_message(
                    f'{{count, {kind}, {case}{{first}} {case}{{second}} other{{last}}}}')
                self.assertTrue(any('duplicate' in e for e in errors), errors)

    def test_unknown_plural_category_is_rejected(self):
        _, errors = l10n_merge.parse_message('{count, plural, feww{few} other{other}}')
        self.assertTrue(any('unknown plural category' in e for e in errors), errors)

    def test_select_values_are_not_plural_categories(self):
        names, errors = l10n_merge.parse_message('{state, select, ready{Ready} failed{Failed} other{Other}}')
        self.assertEqual(names, {'state'})
        self.assertEqual(errors, [])

    def test_russian_categories_with_nested_placeholder_are_valid(self):
        names, errors = l10n_merge.parse_message(
            '{count, plural, =0{Нет файлов} one{{count} файл} few{{count} файла} '
            'many{{count} файлов} other{{count} файла}}')
        self.assertEqual(names, {'count'})
        self.assertEqual(errors, [])

    def test_nested_select_keeps_its_own_cases(self):
        names, errors = l10n_merge.parse_message(
            '{state, select, ready{{count, plural, one{One} other{{count}}}} other{Wait}}')
        self.assertEqual(names, {'state', 'count'})
        self.assertEqual(errors, [])

    def test_existing_relaxed_literal_braces_and_apostrophes_remain_valid(self):
        names, errors = l10n_merge.parse_message("It's JSON: {\"ok\": true}; command {name}")
        self.assertEqual(names, {'name'})
        self.assertEqual(errors, [])


class MergeCliTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name)
        (self.app / 'tool').mkdir()
        self.script = self.app / 'tool/l10n_merge.py'
        shutil.copyfile(Path(l10n_merge.__file__), self.script)
        self.parts = self.app / 'lib/l10n/parts'
        self.parts.mkdir(parents=True)
        self.write('zh', {'title': '标题'})
        self.write('en', {'title': 'Title'})
        self.outputs = [self.parts.parent / f'app_{lang}.arb' for lang in ('zh', 'en')]
        for output in self.outputs:
            output.write_text('existing-output', encoding='utf-8')

    def write(self, lang, data):
        (self.parts / f'probe_{lang}.arb').write_text(
            json.dumps(data, ensure_ascii=False), encoding='utf-8')

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(self.script), *args],
                              capture_output=True, text=True, encoding='utf-8')

    def assert_rejected_without_writes(self, needle):
        result = self.run_cli('--no-gen')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stdout + result.stderr)
        self.assertNotIn('Traceback', result.stdout + result.stderr)
        for output in self.outputs:
            self.assertEqual(output.read_text(encoding='utf-8'), 'existing-output')

    def test_valid_merge_preserves_template_metadata(self):
        self.write('zh', {'title': '{name} 的标题', '@title': {'placeholders': {'name': {'type': 'String'}}}})
        self.write('en', {'title': 'Title for {name}'})
        result = self.run_cli('--no-gen')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        zh, en = [json.loads(output.read_text(encoding='utf-8')) for output in self.outputs]
        self.assertEqual(zh, {'@@locale': 'zh', 'title': '{name} 的标题',
                             '@title': {'placeholders': {'name': {'type': 'String'}}}})
        self.assertEqual(en, {'@@locale': 'en', 'title': 'Title for {name}'})

    def test_duplicate_message_key_is_not_silently_overwritten(self):
        (self.parts / 'probe_en.arb').write_text('{"title":"Correct","title":"Wrong"}', encoding='utf-8')
        self.assert_rejected_without_writes('duplicate key "title"')

    def test_duplicate_nested_metadata_is_rejected(self):
        (self.parts / 'probe_zh.arb').write_text(
            '{"title":"{n}","@title":{"placeholders":{"n":{"type":"int","type":"String"}}}}',
            encoding='utf-8')
        self.assert_rejected_without_writes('duplicate key "type"')

    def test_non_object_root_has_a_clear_diagnostic(self):
        for value in ([], None, 42, 'text'):
            with self.subTest(value=value):
                self.write('zh', value)
                self.assert_rejected_without_writes('ARB root must be an object')

    def test_non_json_constants_are_rejected(self):
        (self.parts / 'probe_zh.arb').write_text('{"title": NaN}', encoding='utf-8')
        self.assert_rejected_without_writes('non-JSON constant NaN')

    def test_empty_placeholder_declaration_does_not_skip_validation(self):
        self.write('zh', {'title': '{name}', '@title': {'placeholders': {}}})
        self.write('en', {'title': '{name}'})
        self.assert_rejected_without_writes('placeholders [] ≠ message [\'name\']')

    def test_metadata_shapes_and_orphan_entries_fail_cleanly(self):
        cases = [
            ({'title': '标题', '@title': 'description'}, 'metadata must be an object'),
            ({'title': '标题', '@title': {'placeholders': []}}, 'placeholders must be an object'),
            ({'title': '标题', '@title': {'placeholders': {'n': 'int'}}}, 'placeholder "n" must be an object'),
            ({'title': '标题', '@missing': {}}, 'orphan metadata'),
        ]
        for data, needle in cases:
            with self.subTest(data=data):
                self.write('zh', data)
                self.assert_rejected_without_writes(needle)

    def test_translation_metadata_is_checked_when_present(self):
        self.write('en', {'title': 'Title', '@title': {'placeholders': {'missing': {'type': 'String'}}}})
        self.assert_rejected_without_writes('en: "@title" placeholders')

    def test_empty_messages_in_either_language_are_rejected(self):
        for lang in ('zh', 'en'):
            with self.subTest(lang=lang):
                self.write('zh', {'title': '标题'})
                self.write('en', {'title': 'Title'})
                self.write(lang, {'title': ' \n\t'})
                self.assert_rejected_without_writes(f'"title" {lang} is empty')

    def test_invalid_icu_prevents_any_output(self):
        self.write('zh', {'title': '{n} 项'})
        self.write('en', {'title': '{n, plural, one{One} one{Again} other{Many}}'})
        self.assert_rejected_without_writes('duplicate plural case "one"')


if __name__ == '__main__':
    unittest.main()
