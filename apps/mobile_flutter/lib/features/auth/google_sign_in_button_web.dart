// Google's JavaScript options use snake_case attribute names by contract.
// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web/web.dart' as web;

import '../../core/network/surf_repository.dart';

@JS('google.accounts.id.initialize')
external void _initializeGoogle(_GoogleOptions options);

@JS('google.accounts.id.renderButton')
external void _renderGoogleButton(
  web.HTMLElement element,
  _GoogleButtonOptions options,
);

extension type _GoogleOptions._(JSObject _) implements JSObject {
  external factory _GoogleOptions({
    required String client_id,
    required String nonce,
    required JSFunction callback,
    bool auto_select,
    bool button_auto_select,
    bool use_fedcm_for_button,
  });
}

extension type _GoogleButtonOptions._(JSObject _) implements JSObject {
  external factory _GoogleButtonOptions({
    String type,
    String theme,
    String size,
    String text,
    String shape,
    double width,
  });
}

extension type _GoogleCredential._(JSObject _) implements JSObject {
  external String? get credential;
}

Future<void>? _googleLibrary;

Future<void> _loadGoogleLibrary() {
  return _googleLibrary ??= () async {
    final completer = Completer<void>();
    final script = web.HTMLScriptElement()
      ..src = 'https://accounts.google.com/gsi/client'
      ..async = true
      ..defer = true;
    script.onLoad.first.then((_) {
      if (!completer.isCompleted) completer.complete();
    });
    script.onError.first.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Google could not load.'));
      }
    });
    web.document.head!.append(script);
    try {
      await completer.future.timeout(const Duration(seconds: 20));
    } catch (_) {
      script.remove();
      _googleLibrary = null;
      rethrow;
    }
  }();
}

class GoogleSignInButton extends ConsumerStatefulWidget {
  const GoogleSignInButton({
    super.key,
    required this.enabled,
    required this.onCredential,
  });

  final bool enabled;
  final Future<void> Function(
    String credential,
    String challengeId,
    String verifier,
  )
  onCredential;

  @override
  ConsumerState<GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends ConsumerState<GoogleSignInButton> {
  // Local visual review only. Production builds leave this false and keep
  // the real Google SDK, origin checks and challenge flow unchanged.
  static const _designPreview = bool.fromEnvironment('AUTH_DESIGN_PREVIEW');
  Map<String, dynamic>? _challenge;
  String? _verifier;
  String? _error;
  bool _available = false;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (!_designPreview) unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    try {
      final repository = ref.read(surfRepositoryProvider);
      final config = await repository.fetchGoogleAuthConfig();
      if (!mounted || generation != _generation || config['enabled'] != true) {
        return;
      }
      setState(() {
        _available = true;
        _error = null;
        _challenge = null;
      });
      final verifier = base64Url
          .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
          .replaceAll('=', '');
      final proof = base64Url
          .encode(sha256.convert(utf8.encode(verifier)).bytes)
          .replaceAll('=', '');
      final challenge = await repository.createGoogleAuthChallenge(proof);
      await _loadGoogleLibrary();
      if (!mounted || generation != _generation) return;
      setState(() {
        _challenge = challenge;
        _verifier = verifier;
      });
    } catch (_) {
      if (mounted && generation == _generation && _available) {
        setState(
          () => _error =
              'Google sign-in could not load. Use email below or try again.',
        );
      }
    }
  }

  void _mountButton(Object element, double width) {
    final challenge = _challenge!;
    final generation = _generation;
    final callback = ((JSObject response) {
      final credential = _GoogleCredential._(response).credential;
      if (!mounted ||
          !widget.enabled ||
          _busy ||
          generation != _generation ||
          credential == null) {
        return;
      }
      _busy = true;
      unawaited(() async {
        try {
          await widget.onCredential(
            credential,
            challenge['challenge_id'] as String,
            _verifier!,
          );
        } finally {
          _busy = false;
          if (mounted) unawaited(_prepare());
        }
      }());
    }).toJS;
    _initializeGoogle(
      _GoogleOptions(
        client_id: challenge['client_id'] as String,
        nonce: challenge['nonce'] as String,
        callback: callback,
        auto_select: false,
        button_auto_select: false,
        use_fedcm_for_button: true,
      ),
    );
    _renderGoogleButton(
      element as web.HTMLElement,
      _GoogleButtonOptions(
        type: 'standard',
        theme: 'outline',
        size: 'large',
        text: 'continue_with',
        shape: 'pill',
        width: width,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_designPreview && !_available) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_designPreview) ...[
          OutlinedButton(
            onPressed: null,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              disabledForegroundColor: const Color(0xFF435B65),
              side: const BorderSide(color: Color(0xFFD7E1E2)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Continue with Google'),
          ),
          const SizedBox(height: 6),
          const Text(
            'Google sign-in is disabled in this local design preview.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Color(0xFF5A6F77)),
          ),
        ] else if (_error != null)
          TextButton(
            onPressed: widget.enabled ? _prepare : null,
            child: Text(_error!),
          )
        else if (_challenge == null)
          const SizedBox(
            height: 44,
            child: Center(child: Text('Loading Google sign-in…')),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth.clamp(120, 320).toDouble();
              return Center(
                child: IgnorePointer(
                  ignoring: !widget.enabled,
                  child: SizedBox(
                    width: width,
                    height: 44,
                    child: HtmlElementView.fromTagName(
                      key: ValueKey('${_challenge!['challenge_id']}:$width'),
                      tagName: 'div',
                      onElementCreated: (element) =>
                          _mountButton(element, width),
                    ),
                  ),
                ),
              );
            },
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Row(
            children: [
              Expanded(child: Divider()),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  'or use email',
                  style: TextStyle(color: Color(0xFF607175)),
                ),
              ),
              Expanded(child: Divider()),
            ],
          ),
        ),
      ],
    );
  }
}
