// 票 #24：输入框里的三种写法各自是谁，装请求由检查结果组装。

import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/install/plugin_spec.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyPluginSpec', () {
    test('npm names, scoped and versioned', () {
      expect(classifyPluginSpec('dsh-plugin-demo'), PluginSpecKind.npm);
      expect(classifyPluginSpec('@scope/plugin'), PluginSpecKind.npm);
      expect(classifyPluginSpec('  @scope/plugin@1.2.3 '), PluginSpecKind.npm);
    });

    test('git shorthand, git URL and git+ prefix', () {
      expect(classifyPluginSpec('you/dsh-plugin'), PluginSpecKind.git);
      expect(classifyPluginSpec('https://github.com/you/dsh-plugin'), PluginSpecKind.git);
      expect(classifyPluginSpec('https://gitlab.com/you/plugin.git'), PluginSpecKind.git);
      expect(classifyPluginSpec('git+https://example.com/x.git'), PluginSpecKind.git);
    });

    test('a tarball link is its own kind', () {
      expect(classifyPluginSpec('https://example.com/plugin.tgz'), PluginSpecKind.tarball);
      expect(classifyPluginSpec('https://example.com/plugin.tar.gz'), PluginSpecKind.tarball);
    });

    test('what the page never sends', () {
      expect(classifyPluginSpec(''), PluginSpecKind.invalid);
      expect(classifyPluginSpec('   '), PluginSpecKind.invalid);
      expect(classifyPluginSpec('two words'), PluginSpecKind.invalid);
      expect(classifyPluginSpec('./local/dir'), PluginSpecKind.invalid, reason: 'no directory picker on a phone');
      expect(classifyPluginSpec('/root/plugin'), PluginSpecKind.invalid);
      expect(classifyPluginSpec('https://example.com/plugin'), PluginSpecKind.invalid, reason: 'not git, not a tarball');
    });
  });

  group('customInstallRequest', () {
    test('takes the name from the inspection and keeps the typed spec', () {
      const inspection = PluginInspectionAccepted(kind: 'git', name: 'dsh-plugin-demo', version: '1.0.0');
      final request = customInstallRequest(inspection, ' you/dsh-plugin ');
      expect(request, isNotNull);
      expect(request!.name, 'dsh-plugin-demo');
      expect(request.spec, 'you/dsh-plugin');
      expect(request.replaceInstalled, isFalse);
      expect(customInstallRequest(inspection, 'x', replace: true)!.replaceInstalled, isTrue);
    });

    test('a registry answer carries its registry through', () {
      const inspection = PluginInspectionAccepted(kind: 'registry', name: '@s/p', registry: 'https://r.example');
      expect(customInstallRequest(inspection, '@s/p')!.registry, 'https://r.example');
    });

    test('an inspection without a name cannot be installed', () {
      const inspection = PluginInspectionAccepted(kind: 'registry');
      expect(customInstallRequest(inspection, '@s/p'), isNull);
    });
  });
}
