import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wgc_ne/wgc_ne.dart';

import 'configuration_test.dart' show configurationJson;

Matcher isFailure(WgcErrorCode kind) =>
    isA<WgcException>().having((error) => error.kind, 'kind', kind);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.idy.wgc_ne/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  WgcNe client({Duration timeout = const Duration(seconds: 2)}) => WgcNe(
        providerBundleIdentifier: 'dev.example.consumer.tunnel',
        keychainAccessGroup: 'TEAM.dev.example.shared',
        channel: channel,
        pollingInterval: const Duration(seconds: 1),
        requestTimeout: timeout,
      );

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('methods use the exact native channel arguments', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'state': call.method == 'start' ? 'connecting' : 'disconnected'};
    });
    final api = client();
    final configuration = WgcConfiguration.fromJson(configurationJson());
    expect(
        (await api.start(configuration)).state, WgcConnectionState.connecting);
    await api.stop();
    await api.status();
    await api.removeProfile();
    expect(calls.map((call) => call.method),
        ['start', 'stop', 'status', 'removeProfile']);
    expect(calls.first.arguments, {
      'providerBundleIdentifier': api.providerBundleIdentifier,
      'keychainAccessGroup': api.keychainAccessGroup,
      'configuration': configuration.toJsonString(),
    });
    for (final call in calls.skip(1)) {
      expect(call.arguments,
          {'providerBundleIdentifier': api.providerBundleIdentifier});
    }
    await api.dispose();
  });

  test('native errors and unknown replies are redacted', () async {
    const secret = 'sensitive-native-error-detail';
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
          code: 'profile_conflict',
          message: secret,
          details: {'secret': secret});
    });
    final api = client();
    try {
      await api.status();
      fail('Must fail');
    } on WgcException catch (error) {
      expect(error.kind, WgcErrorCode.profileConflict);
      expect(error.toString(), isNot(contains(secret)));
    }
    messenger.setMockMethodCallHandler(channel, (_) async => {'state': secret});
    await expectLater(
        api.status(),
        throwsA(isA<WgcException>().having(
            (error) => error.kind, 'kind', WgcErrorCode.invalidResponse)));
    await api.dispose();
  });

  test('polling exists only while listeners exist and stops on disposal', () {
    fakeAsync((clock) {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return {'state': 'disconnected'};
      });
      final api = client();
      clock.elapse(const Duration(seconds: 3));
      expect(calls, 0);
      final first = api.statuses.listen((_) {});
      final second = api.statuses.listen((_) {});
      clock.flushMicrotasks();
      expect(calls, 1);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(calls, 2);
      unawaited(first.cancel());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(calls, 3);
      unawaited(second.cancel());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 3));
      expect(calls, 3);
      final third = api.statuses.listen((_) {});
      clock.flushMicrotasks();
      expect(calls, 4);
      third.pause();
      var disposed = false;
      unawaited(api.dispose().then((_) {
        disposed = true;
      }));
      clock.flushMicrotasks();
      expect(disposed, isTrue,
          reason: 'A paused consumer cannot block disposal');
      clock.elapse(const Duration(seconds: 3));
      expect(calls, 4);
      unawaited(third.cancel());
      clock.flushMicrotasks();
      expect(clock.periodicTimerCount, 0);
      expect(() => api.statuses, throwsA(isA<WgcException>()));
    });
  });

  test('hung requests are bounded and polling never overlaps', () {
    fakeAsync((clock) {
      var calls = 0;
      final reply = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) {
        calls++;
        return reply.future;
      });
      final api = client(timeout: const Duration(milliseconds: 200));
      final errors = <Object>[];
      final subscription = api.statuses.listen((_) {}, onError: errors.add);
      clock.flushMicrotasks();
      Object? manualError;
      unawaited(api
          .status()
          .then<void>((_) => fail('A hung status call must time out'),
              onError: (Object error) {
        manualError = error;
      }));
      clock.elapse(const Duration(milliseconds: 250));
      clock.flushMicrotasks();
      expect(calls, 1);
      expect(
          manualError,
          isA<WgcException>()
              .having((error) => error.kind, 'kind', WgcErrorCode.timeout));
      expect(errors.single, isA<WgcException>());
      unawaited(subscription.cancel());
      reply.complete({'state': 'connected'});
      clock.flushMicrotasks();
      unawaited(api.dispose());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 3));
      expect(calls, 1);
      expect(clock.periodicTimerCount, 0);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('a paused subscription stops its polling and buffers nothing', () {
    fakeAsync((clock) {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return {'state': 'disconnected'};
      });
      final api = client();
      var pausedEvents = 0;
      var activeEvents = 0;
      final paused = api.statuses.listen((_) => pausedEvents++);
      final active = api.statuses.listen((_) => activeEvents++);
      clock.flushMicrotasks();
      expect((calls, pausedEvents, activeEvents), (1, 1, 1));

      paused.pause();
      clock.elapse(const Duration(seconds: 2));
      expect((calls, pausedEvents, activeEvents), (3, 1, 3));

      unawaited(active.cancel());
      clock.flushMicrotasks();
      expect(clock.periodicTimerCount, 0);
      clock.elapse(const Duration(seconds: 5));
      expect(calls, 3);

      paused.resume();
      clock.flushMicrotasks();
      expect((calls, pausedEvents), (4, 2));

      unawaited(paused.cancel());
      unawaited(api.dispose());
      clock.flushMicrotasks();
      expect(clock.periodicTimerCount, 0);
    });
  });

  test('disposal releases deadlines and fails pending calls', () {
    fakeAsync((clock) {
      final reply = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => reply.future);
      final api = client();
      final stream = api.statuses;
      final subscription = stream.listen((_) {});
      Object? failure;
      unawaited(api
          .stop()
          .then<void>((_) => fail('Disposal must fail pending calls'),
              onError: (Object error) {
        failure = error;
      }));
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 2,
          reason: 'The poll and the stop call each hold a deadline');

      unawaited(api.dispose());
      clock.flushMicrotasks();
      expect(failure, isFailure(WgcErrorCode.disposed));
      expect(clock.periodicTimerCount, 0);
      expect(clock.nonPeriodicTimerCount, 0);

      reply.complete({'state': 'connected'});
      clock.flushMicrotasks();
      var done = false;
      stream.listen(null, onDone: () => done = true);
      clock.flushMicrotasks();
      expect(done, isTrue, reason: 'A late listener must not start polling');
      expect(clock.periodicTimerCount, 0);
      unawaited(subscription.cancel());
    });
  });

  test('calls after disposal fail through their futures', () async {
    final api = client();
    await api.dispose();
    await expectLater(api.status(), throwsA(isFailure(WgcErrorCode.disposed)));
    await expectLater(api.stop(), throwsA(isFailure(WgcErrorCode.disposed)));
    await api.dispose();
  });

  test('malformed counters and sensitive unknown fields cannot escape', () {
    final status = WgcStatus.fromMap({
      'state': 'connected',
      'core': {
        'state': 'running',
        'bytes_sent': 7,
        'private_key': 'secret',
        'configuration': {'token': 'secret'},
      }
    });
    expect(status.core?.bytesSent, 7);
    expect(status.toString(), isNot(contains('secret')));
    expect(
        () => WgcStatus.fromMap({
              'state': 'connected',
              'core': {'state': 'running', 'bytes_sent': -1}
            }),
        throwsA(isA<WgcException>()));
  });
}
