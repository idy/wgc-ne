import 'dart:async';

import 'package:flutter/services.dart';

import 'configuration.dart';
import 'status.dart';

/// A client for one containing app's provider. Dispose it when its owner is closed.
final class WgcNe {
  WgcNe({
    required this.providerBundleIdentifier,
    required this.keychainAccessGroup,
    this.localizedDescription,
    this.pollingInterval = const Duration(seconds: 1),
    this.requestTimeout = const Duration(seconds: 45),
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('dev.idy.wgc_ne/methods') {
    if (!_identifier(providerBundleIdentifier) ||
        !_identifier(keychainAccessGroup) ||
        (localizedDescription != null &&
            (localizedDescription!.isEmpty ||
                localizedDescription!.length > 255)) ||
        pollingInterval < const Duration(milliseconds: 100) ||
        pollingInterval > const Duration(minutes: 1) ||
        requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(minutes: 2)) {
      throw const WgcException(WgcErrorCode.invalidArguments);
    }
  }

  final String providerBundleIdentifier;
  final String keychainAccessGroup;
  final String? localizedDescription;
  final Duration pollingInterval;
  final Duration requestTimeout;
  final MethodChannel _channel;
  late final Stream<WgcStatus> _statuses =
      Stream<WgcStatus>.multi(_attach, isBroadcast: true);
  final Set<MultiStreamController<WgcStatus>> _subscribers = {};
  final Set<_NativeCall> _calls = {};
  Timer? _timer;
  Future<WgcStatus>? _statusRequest;
  bool _pollInFlight = false;
  bool _disposed = false;
  int _pollGeneration = 0;

  /// Polling runs only while at least one subscription is listening and not
  /// paused. A paused subscription buffers nothing and receives the next status
  /// after it resumes. Errors are fixed WgcException values.
  Stream<WgcStatus> get statuses {
    if (_disposed) {
      throw const WgcException(WgcErrorCode.disposed);
    }
    return _statuses;
  }

  Future<WgcStatus> start(WgcConfiguration configuration) => _invoke('start', {
        'providerBundleIdentifier': providerBundleIdentifier,
        'keychainAccessGroup': keychainAccessGroup,
        'configuration': configuration.toJsonString(),
        if (localizedDescription != null)
          'localizedDescription': localizedDescription,
      });

  Future<WgcStatus> stop() => _invoke('stop', _providerArguments);

  /// Invoke only in response to an explicit user action.
  Future<WgcStatus> removeProfile() =>
      _invoke('removeProfile', _providerArguments);

  Future<WgcStatus> status() {
    if (_disposed) {
      return Future<WgcStatus>.error(const WgcException(WgcErrorCode.disposed));
    }
    final pending = _statusRequest;
    if (pending != null) {
      return pending;
    }
    final request = _invoke('status', _providerArguments);
    _statusRequest = request;
    // Attach cleanup to both branches without creating an unobserved error future.
    request.then<void>((_) {
      if (identical(_statusRequest, request)) _statusRequest = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_statusRequest, request)) _statusRequest = null;
    });
    return request;
  }

  Map<String, Object?> get _providerArguments =>
      {'providerBundleIdentifier': providerBundleIdentifier};

  Future<WgcStatus> _invoke(String method, Map<String, Object?> arguments) {
    if (_disposed) {
      return Future<WgcStatus>.error(const WgcException(WgcErrorCode.disposed));
    }
    final call = _NativeCall(requestTimeout, _calls.remove);
    _calls.add(call);
    unawaited(_dispatch(call, method, arguments));
    return call.future;
  }

  Future<void> _dispatch(
      _NativeCall call, String method, Map<String, Object?> arguments) async {
    try {
      final reply = await _channel.invokeMethod<Object?>(method, arguments);
      call.succeed(WgcStatus.fromMap(reply));
    } on WgcException catch (error) {
      call.fail(error);
    } on PlatformException catch (error) {
      final kind = WgcErrorCode.values
              .where((kind) => kind.code == error.code)
              .firstOrNull ??
          WgcErrorCode.internalError;
      call.fail(WgcException(kind));
    } on MissingPluginException {
      call.fail(const WgcException(WgcErrorCode.unsupportedPlatform));
    } catch (_) {
      call.fail(const WgcException(WgcErrorCode.internalError));
    }
  }

  void _attach(MultiStreamController<WgcStatus> subscriber) {
    if (_disposed) {
      unawaited(subscriber.close());
      return;
    }
    _subscribers.add(subscriber);
    subscriber
      ..onPause = _syncPolling
      ..onResume = _syncPolling
      ..onCancel = () {
        _subscribers.remove(subscriber);
        _syncPolling();
      };
    _syncPolling();
  }

  void _syncPolling() {
    if (_disposed || _subscribers.every((subscriber) => subscriber.isPaused)) {
      _stopPolling();
    } else if (_timer == null) {
      final generation = ++_pollGeneration;
      _timer = Timer.periodic(pollingInterval, (_) => _poll(generation));
      unawaited(_poll(generation));
    }
  }

  void _stopPolling() {
    _pollGeneration++;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll(int generation) async {
    if (_pollInFlight || generation != _pollGeneration) {
      return;
    }
    _pollInFlight = true;
    try {
      final value = await status();
      if (generation == _pollGeneration) {
        _publish((subscriber) => subscriber.add(value));
      }
    } on WgcException catch (error, stack) {
      if (generation == _pollGeneration) {
        _publish((subscriber) => subscriber.addError(error, stack));
      }
    } finally {
      _pollInFlight = false;
    }
  }

  void _publish(void Function(MultiStreamController<WgcStatus>) deliver) {
    for (final subscriber in _subscribers) {
      if (!subscriber.isPaused) {
        deliver(subscriber);
      }
    }
  }

  /// Releases every timer and closes the status stream. Pending calls fail with
  /// [WgcErrorCode.disposed], although the native side may still finish them.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _stopPolling();
    for (final call in _calls.toList()) {
      call.fail(const WgcException(WgcErrorCode.disposed));
    }
    final subscribers = _subscribers.toList();
    _subscribers.clear();
    for (final subscriber in subscribers) {
      // A paused subscriber can delay close's future indefinitely, and nothing
      // remains to wait for, so disposal never depends on the consumer.
      unawaited(subscriber.close());
    }
  }
}

/// One native call. Future.timeout keeps its timer until it fires, so this uses
/// a plain Timer that settling or disposal can cancel.
final class _NativeCall {
  _NativeCall(Duration limit, this._onSettled) {
    _deadline =
        Timer(limit, () => fail(const WgcException(WgcErrorCode.timeout)));
  }

  final void Function(_NativeCall) _onSettled;
  final Completer<WgcStatus> _completer = Completer<WgcStatus>();
  late final Timer _deadline;

  Future<WgcStatus> get future => _completer.future;

  void succeed(WgcStatus status) {
    if (_settle()) {
      _completer.complete(status);
    }
  }

  void fail(WgcException error) {
    if (_settle()) {
      _completer.completeError(error);
    }
  }

  bool _settle() {
    if (_completer.isCompleted) {
      return false;
    }
    _deadline.cancel();
    _onSettled(this);
    return true;
  }
}

bool _identifier(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value);
