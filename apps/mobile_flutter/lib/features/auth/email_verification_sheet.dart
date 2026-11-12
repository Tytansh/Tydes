import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error_message.dart';
import '../../core/network/demo_persistence.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart' show meProvider;

final emailVerificationApiProvider = Provider(
  (ref) => EmailVerificationApi(
    ref.watch(dioProvider),
    ref.watch(demoPersistenceProvider),
  ),
);

/// Uses the signed-in account's address, never an address supplied by the UI.
class EmailVerificationApi {
  EmailVerificationApi(this.dio, this.persistence);
  final Dio dio;
  final DemoPersistence persistence;

  Future<EmailVerificationSession> openSession(String accountId) async {
    final token = await persistence.loadAccessToken();
    if (token == null || token.isEmpty) {
      throw StateError('Please sign in again to verify your email.');
    }
    final session = EmailVerificationSession(
      dio,
      persistence,
      accountId,
      token,
    );
    final user = await session._request('GET', '/users/me');
    if (user['id'] != accountId) throw _accountChanged();
    return session;
  }
}

StateError _accountChanged() =>
    StateError('Your account changed. Close this window and try again.');

class EmailVerificationSession {
  EmailVerificationSession(
    this.dio,
    this.persistence,
    this.accountId,
    this._token,
  );
  final Dio dio;
  final DemoPersistence persistence;
  final String accountId;
  final String _token;

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? data,
  }) async {
    if (await persistence.loadAccessToken() != _token) throw _accountChanged();
    final response = await dio.request<Map<String, dynamic>>(
      path,
      data: data,
      options: Options(
        method: method,
        headers: {'Authorization': 'Bearer $_token'},
      ),
    );
    if (await persistence.loadAccessToken() != _token) throw _accountChanged();
    if (response.data == null) {
      throw StateError('Email verification was not confirmed. Try again.');
    }
    return response.data!;
  }

  Future<EmailVerificationDispatch> requestCode() async {
    final result = await _request('POST', '/auth/email-verification/request');
    final address = result['verification_sent_to'];
    final alreadyVerified = result['already_verified'] == true;
    if (alreadyVerified) return const EmailVerificationDispatch(null, true);
    if (result['sent'] != true || address is! String || address.isEmpty) {
      throw StateError('The code could not be sent. Try again.');
    }
    return EmailVerificationDispatch(address, alreadyVerified);
  }

  Future<void> confirm(String code) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw StateError('Enter the six-digit code from your email.');
    }
    final result = await _request(
      'POST',
      '/auth/email-verification/confirm',
      data: {'code': code},
    );
    if (result['id'] != accountId || result['email_verified'] != true) {
      throw StateError('Email verification was not confirmed. Try again.');
    }
  }
}

class EmailVerificationDispatch {
  const EmailVerificationDispatch(this.email, this.alreadyVerified);
  final String? email;
  final bool alreadyVerified;
}

/// Returns true only after this account's verification was confirmed by server.
Future<bool> showEmailVerificationSheet(
  BuildContext context, {
  required String accountId,
  required String email,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) =>
          _EmailVerificationSheet(accountId: accountId, email: email),
    ) ??
    false;

class _EmailVerificationSheet extends ConsumerStatefulWidget {
  const _EmailVerificationSheet({required this.accountId, required this.email});
  final String accountId;
  final String email;

  @override
  ConsumerState<_EmailVerificationSheet> createState() =>
      _EmailVerificationSheetState();
}

class _EmailVerificationSheetState
    extends ConsumerState<_EmailVerificationSheet> {
  final _code = TextEditingController();
  EmailVerificationSession? _session;
  bool _busy = false;
  String? _sentTo;
  String? _error;

  bool get _sameAccount =>
      ref.read(meProvider).valueOrNull?.id == widget.accountId;

  Future<void> _act({required bool confirm}) async {
    if (_busy) return;
    if (!_sameAccount) {
      setState(() => _error = friendlyErrorMessage(_accountChanged()));
      return;
    }
    if (confirm && !RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      setState(() => _error = 'Enter the six-digit code from your email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _session ??= await ref
          .read(emailVerificationApiProvider)
          .openSession(widget.accountId);
      if (!mounted) return;
      if (!_sameAccount) throw _accountChanged();
      if (confirm) {
        await _session!.confirm(_code.text.trim());
        if (!mounted) return;
        if (!_sameAccount) throw _accountChanged();
        Navigator.of(context).pop(true);
      } else {
        final dispatch = await _session!.requestCode();
        if (!mounted) return;
        if (!_sameAccount) throw _accountChanged();
        if (dispatch.alreadyVerified) {
          Navigator.of(context).pop(true);
        } else {
          setState(() => _sentTo = dispatch.email);
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ownerId = ref.watch(
      meProvider.select((value) => value.valueOrNull?.id),
    );
    final accountChanged = ownerId != widget.accountId;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          8,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Verify your email',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              accountChanged
                  ? 'Your account changed. Close this window and try again.'
                  : _sentTo == null
                  ? 'Verify ${widget.email} to start conversations and send messages. We’ll send a six-digit code when you’re ready.'
                  : 'Enter the six-digit code sent to $_sentTo. It expires in 15 minutes. Check your spam folder too.',
            ),
            if (!accountChanged && _sentTo != null) ...[
              const SizedBox(height: 20),
              TextField(
                key: const ValueKey('email-verification-code'),
                controller: _code,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Verification code',
                ),
                onSubmitted: (_) => _act(confirm: true),
              ),
            ],
            if (_error != null && !accountChanged) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            if (!accountChanged) ...[
              FilledButton(
                onPressed: _busy ? null : () => _act(confirm: _sentTo != null),
                child: Text(
                  _busy
                      ? 'Please wait…'
                      : _sentTo == null
                      ? 'Send code'
                      : 'Verify email',
                ),
              ),
              if (_sentTo != null)
                TextButton(
                  onPressed: _busy ? null : () => _act(confirm: false),
                  child: const Text('Resend code'),
                ),
            ],
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
