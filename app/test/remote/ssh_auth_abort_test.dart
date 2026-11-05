// A connection lost during authentication says nothing about the credentials.
// Treated as a rejected key it stopped every automatic retry (#567).
import 'package:dartssh2/dartssh2.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';

void main() {
  const params = SshConnectParams(
    host: '100.64.0.1',
    port: 22,
    username: 'me',
    auth: SshAuthMethod.privateKey,
    secrets: SshSecrets(password: 'pw'),
  );

  test('a connection closed before authentication finished can be retried', () {
    final error = DartSshTransport.describeSshError(
      SSHAuthAbortError('Connection closed before authentication'),
      params,
    );
    expect(error.kind, HostLinkErrorKind.unreachable);
    expect(error.retryable, isTrue);
  });

  test('authentication that timed out can be retried', () {
    final error = DartSshTransport.describeSshError(SSHAuthAbortError('Authentication timed out'), params);
    expect(error.kind, HostLinkErrorKind.unreachable);
    expect(error.retryable, isTrue);
  });

  test('a rejected key stays rejected, with no retry', () {
    final error = DartSshTransport.describeSshError(SSHAuthFailError('All authentication methods failed'), params);
    expect(error.kind, HostLinkErrorKind.authFailed);
    expect(error.retryable, isFalse);
  });

  test('the link carries on past a dropped authentication and connects', () async {
    var attempts = 0;
    final link = SshHostLink(
      config: sampleSsh,
      loadSecrets: () async => const SshSecrets(password: 'pw'),
      transportFactory: (connect, _) async {
        attempts++;
        if (attempts == 1) {
          throw DartSshTransport.describeSshError(
            SSHAuthAbortError('Connection closed before authentication'),
            connect,
          );
        }
        return FakeTransport(FakeRemote());
      },
      connectClient: FakeConnector().call,
      backoff: Backoff(
        initial: const Duration(milliseconds: 10),
        max: const Duration(milliseconds: 40),
        maxAttempts: 5,
      ),
    );
    addTearDown(link.close);
    await link.open().timeout(const Duration(seconds: 5));
    expect(attempts, 2);
    expect(link.status.isConnected, isTrue);
  });
}
