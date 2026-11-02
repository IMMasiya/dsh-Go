// 票 #24 的页面路径：输入 → 检查 → 结果三行（包名 / 版本 / 来源）。
// 不测 golden，也不起真主机：inspect 由假 carrier 回答。

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/plugins/install/plugin_install_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('a typed spec is checked and its name, version and source shown', (tester) async {
    final fake = FakePluginCarrier();
    fake.handlers['pluginManager/inspect'] = (_) => {
      'status': 'accepted',
      'kind': 'registry',
      'name': '@scope/plugin',
      'version': '1.2.3',
      'description': '演示插件',
    };
    final client = DshClient.withCarrier(fake);

    await tester.pumpWidget(
      testApp(
        const PluginInstallPage(canInstall: true, safeMode: false),
        overrides: [
          activeConnectionProvider.overrideWith(
            (ref) => AsyncData(HostConnection(client: client, isLocal: true, label: 'local')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '@scope/plugin');
    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();

    expect(find.text('@scope/plugin'), findsWidgets);
    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.text('npm 包'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget);
  });

  testWidgets('an unusable spec never reaches the host', (tester) async {
    final fake = FakePluginCarrier();
    var asked = 0;
    fake.handlers['pluginManager/inspect'] = (_) {
      asked++;
      return {'status': 'accepted', 'kind': 'registry', 'name': 'x'};
    };
    final client = DshClient.withCarrier(fake);

    await tester.pumpWidget(
      testApp(
        const PluginInstallPage(canInstall: true, safeMode: false),
        overrides: [
          activeConnectionProvider.overrideWith(
            (ref) => AsyncData(HostConnection(client: client, isLocal: true, label: 'local')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), './local/dir');
    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();

    expect(asked, 0, reason: 'a local path is refused before any request');
    expect(find.textContaining('写法不认识'), findsOneWidget);
  });
}
