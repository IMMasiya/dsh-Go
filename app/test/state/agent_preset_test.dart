// 票 #23：Agent 预设跟着「下一个对话」走 —— 选择存起来、创建时带上、用掉就清。

import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../plugins/support/fake_plugin_host.dart';

AgentPresetInfo _preset(String id, {bool isDefault = false, String? name}) =>
    AgentPresetInfo(id: id, isDefault: isDefault, name: name ?? id);

void main() {
  group('createSessionInWorkspace', () {
    test('carries the picked preset on both create paths, and nothing when none is picked', () async {
      final fake = FakePluginCarrier();
      final requests = <Map<String, Object?>>[];
      var calls = 0;
      fake.handlers['session/create'] = (args) {
        final request = (args['request'] as Map?)?.cast<String, Object?>() ?? const {};
        requests.add(request);
        calls++;
        // The first call is the workspace path; the host says the workspace is
        // gone, so the client falls back to cwd.
        if (calls == 1) return {'sessionId': 's1', 'agentPreset': request['agentPreset']};
        return {'sessionId': 's2', 'agentPreset': request['agentPreset']};
      };
      final client = DshClient.withCarrier(fake);

      final created = await createSessionInWorkspace(client, 'ws-1', agentPreset: 'research');
      expect(created.sessionId, 's1');
      expect(requests.single['agentPreset'], 'research');

      await createSessionInWorkspace(client, null, cwd: '/w');
      expect(requests.last.containsKey('agentPreset'), isFalse, reason: 'no pick, no field: the host default stands');
    });
  });

  group('pendingAgentPresetProvider', () {
    test('stores an id, and clears on null or empty', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(pendingAgentPresetProvider.notifier);

      expect(container.read(pendingAgentPresetProvider), isNull);
      notifier.select('research');
      expect(container.read(pendingAgentPresetProvider), 'research');
      notifier.select('');
      expect(container.read(pendingAgentPresetProvider), isNull);
      notifier.select('plan');
      notifier.select(null);
      expect(container.read(pendingAgentPresetProvider), isNull);
    });
  });

  group('agentPresetFor', () {
    test('a pending pick wins, else the host default, else the first', () {
      final presets = [_preset('a'), _preset('b', isDefault: true), _preset('c')];
      expect(agentPresetFor(presets, 'c')?.id, 'c');
      expect(agentPresetFor(presets, null)?.id, 'b', reason: 'no pick follows the host default');
      expect(agentPresetFor(presets, 'gone')?.id, 'b', reason: 'an unknown id falls back to the default');
      expect(agentPresetFor([_preset('only')], null)?.id, 'only');
      expect(agentPresetFor(const <AgentPresetInfo>[], 'x'), isNull);
      expect(agentPresetFor(null, 'x'), isNull);
    });

    test('the row shows a readable name', () {
      final presets = [_preset('a', name: '标准模式')];
      expect(agentPresetFor(presets, 'a')?.name, '标准模式');
    });
  });
}
