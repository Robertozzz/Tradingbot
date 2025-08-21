import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Relative URLs work for web (same origin behind Nginx).
/// For desktop/mobile later, pass a baseUrl via constructor/env.
String _u(String path, [String base = '']) {
  return path.startsWith('/') ? path : '/$path';
  //return ('http://192.168.133.130${path.startsWith('/') ? path : '/$path'}');
}

enum AuthStage { checking, init, enroll, login, ready }

class AuthGate extends StatefulWidget {
  final Widget child; // Your real app once logged in
  final String baseUrl; // optional for non-web targets later
  const AuthGate({super.key, required this.child, this.baseUrl = ''});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AuthStage stage = AuthStage.checking;
  // Remember creds during first-run so we can auto-login after TOTP
  String? _initUser;
  String? _initPass;
  String msg = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final v = await http.get(Uri.parse(_u('/auth/validate', widget.baseUrl)));
    if (v.statusCode == 200) {
      setState(() => stage = AuthStage.ready);
      return;
    }

    final s = await http.get(Uri.parse(_u('/auth/state', widget.baseUrl)));
    if (s.statusCode == 200) {
      final st = (jsonDecode(s.body)['stage'] as String?) ?? 'login';
      setState(() {
        stage = switch (st) {
          'init' => AuthStage.init,
          'enroll' => AuthStage.enroll,
          _ => AuthStage.login
        };
        msg = '';
      });
    } else if (s.statusCode == 404) {
      // backend is older/missing /state → assume first run
      setState(() {
        stage = AuthStage.init;
        msg = '';
      });
    } else {
      setState(() {
        stage = AuthStage.login;
        msg = 'Server unavailable (${s.statusCode})';
      });
    }
  }

  Future<void> _initPassword(String user, String pw) async {
    setState(() => msg = '');
    _initUser = user;
    _initPass = pw;
    final r = await http.post(
      Uri.parse(_u('/auth/init', widget.baseUrl)),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': user, 'new_password': pw}),
    );
    if (r.statusCode == 200) {
      setState(() => stage = AuthStage.enroll);
    } else {
      setState(() => msg = 'Init failed (${r.statusCode})');
    }
  }

  Future<void> _enroll(String code) async {
    setState(() => msg = '');
    final r = await http.post(
      Uri.parse(_u('/auth/enroll', widget.baseUrl)),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'code': code}),
    );
    if (r.statusCode == 200) {
      // Prefer backend cookie set on /enroll; otherwise fall back to logging in
      if (_initUser != null && _initPass != null) {
        final lr = await http.post(
          Uri.parse(_u('/auth/login', widget.baseUrl)),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'username': _initUser,
            'password': _initPass,
            'code': code,
            'remember': true,
          }),
        );
        if (lr.statusCode == 200) {
          setState(() => stage = AuthStage.ready);
          return;
        }
      }
      // If backend already set the cookie on /enroll, this will pass:
      final v = await http.get(Uri.parse(_u('/auth/validate', widget.baseUrl)));
      setState(() =>
          stage = v.statusCode == 200 ? AuthStage.ready : AuthStage.login);
    } else {
      setState(() => msg = 'Enrollment failed (${r.statusCode})');
    }
  }

  Future<void> _resetAccount() async {
    final r = await http.post(
      Uri.parse(_u('/auth/reset', widget.baseUrl)),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'confirm': true}),
    );
    if (r.statusCode == 200) {
      setState(() {
        msg = 'Account reset. Set up a new username & password.';
        stage = AuthStage.init;
      });
    } else {
      setState(() => msg = 'Reset failed (${r.statusCode})');
    }
  }

  Future<void> _login(
      String user, String pass, String code, bool remember) async {
    setState(() => msg = '');
    final r = await http.post(
      Uri.parse(_u('/auth/login', widget.baseUrl)),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': user,
        'password': pass,
        'code': code,
        'remember': remember
      }),
    );
    setState(
        () => stage = r.statusCode == 200 ? AuthStage.ready : AuthStage.login);
    if (r.statusCode != 200) msg = 'Login failed (${r.statusCode})';
  }

  @override
  Widget build(BuildContext context) {
    switch (stage) {
      case AuthStage.ready:
        return widget.child;
      case AuthStage.checking:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case AuthStage.init:
        return _InitPassword(onSubmit: _initPassword, msg: msg);
      case AuthStage.enroll:
        return _EnrollTotp(
            onSubmit: _enroll, msg: msg, baseUrl: widget.baseUrl);
      case AuthStage.login:
        return _Login(onSubmit: _login, msg: msg, onReset: _resetAccount);
    }
  }
}

class _InitPassword extends StatefulWidget {
  final Future<void> Function(String user, String pw) onSubmit;
  final String msg;
  const _InitPassword({required this.onSubmit, required this.msg});
  @override
  State<_InitPassword> createState() => _InitPasswordState();
}

class _InitPasswordState extends State<_InitPassword> {
  final u = TextEditingController();
  final p1 = TextEditingController();
  final p2 = TextEditingController();
  bool showPw = false;
  bool busy = false;
  final _fUser = FocusNode();
  final _fPw1 = FocusNode();
  final _fPw2 = FocusNode();

  @override
  void initState() {
    super.initState();
    // Rebuild as the user types so _canContinue() reevaluates live
    u.addListener(_onChange);
    p1.addListener(_onChange);
    p2.addListener(_onChange);
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    u.removeListener(_onChange);
    p1.removeListener(_onChange);
    p2.removeListener(_onChange);
    u.dispose();
    p1.dispose();
    p2.dispose();
    _fUser.dispose();
    _fPw1.dispose();
    _fPw2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _CardShell(
        title: 'First-time setup',
        children: [
          const Text(
              'Choose a username and password. You’ll enroll TOTP next.'),
          const SizedBox(height: 12),
          TextField(
            controller: u,
            focusNode: _fUser,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _fPw1.requestFocus(),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: 'Username (3–32 chars, A–Z, 0–9, _.-)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: p1,
            focusNode: _fPw1,
            obscureText: !showPw,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _fPw2.requestFocus(),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'New password (min 8)',
              // Prevent the eye button from stealing keyboard focus
              suffixIcon: Focus(
                canRequestFocus: false,
                child: IconButton(
                  onPressed: () => setState(() => showPw = !showPw),
                  icon: Icon(showPw ? Icons.visibility_off : Icons.visibility),
                  tooltip: showPw ? 'Hide password' : 'Show password',
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: p2,
            focusNode: _fPw2,
            obscureText: !showPw,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) async {
              if (!_canContinue()) return;
              await _submit();
            },
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Repeat password'),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(shape: const StadiumBorder()),
                onPressed: busy || !_canContinue()
                    ? null
                    : () async {
                        await _submit();
                      },
                child: const Text('Continue'),
              ),
            ],
          ),
          if (widget.msg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(widget.msg,
                  style: const TextStyle(color: Colors.redAccent)),
            ),
        ],
      );

  bool _canContinue() {
    final user = u.text.trim();
    final pw1 = p1.text;
    final pw2 = p2.text;
    return user.length >= 3 && pw1.length >= 8 && pw1 == pw2;
  }

  Future<void> _submit() async {
    setState(() => busy = true);
    await widget.onSubmit(u.text.trim(), p1.text);
    setState(() => busy = false);
  }
}

class _EnrollTotp extends StatefulWidget {
  final Future<void> Function(String) onSubmit;
  final String msg;
  final String baseUrl;
  const _EnrollTotp(
      {required this.onSubmit, required this.msg, required this.baseUrl});
  @override
  State<_EnrollTotp> createState() => _EnrollTotpState();
}

class _EnrollTotpState extends State<_EnrollTotp> {
  final c = TextEditingController();
  @override
  Widget build(BuildContext context) => _CardShell(
        title: 'Enroll TOTP',
        children: [
          const Text(
              'Scan the QR with Google Authenticator, then enter your 6-digit code.'),
          const SizedBox(height: 12),
          // cache-busting query param
          Image.network(
            _u('/auth/enroll_qr?ts=${DateTime.now().millisecondsSinceEpoch}',
                widget.baseUrl),
            height: 180,
          ),
          const SizedBox(height: 12),
          TextField(
              controller: c,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) async => await widget.onSubmit(c.text),
              decoration: const InputDecoration(labelText: '6-digit code')),
          const SizedBox(height: 12),
          ElevatedButton(
              onPressed: () async => await widget.onSubmit(c.text),
              child: const Text('Verify')),
          if (widget.msg.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(widget.msg,
                    style: const TextStyle(color: Colors.redAccent))),
        ],
      );
}

class _Login extends StatefulWidget {
  final Future<void> Function(String, String, String, bool) onSubmit;
  final String msg;
  final VoidCallback onReset;
  const _Login(
      {required this.onSubmit, required this.msg, required this.onReset});
  @override
  State<_Login> createState() => _LoginState();
}

class _LoginState extends State<_Login> {
  final u = TextEditingController(text: '');
  final p = TextEditingController();
  final c = TextEditingController();
  bool remember = false;
  bool busy = false;
  final _fUser = FocusNode();
  final _fPw = FocusNode();
  final _fCode = FocusNode();

  @override
  Widget build(BuildContext context) => _CardShell(
        title: 'Sign in',
        children: [
          TextField(
              controller: u,
              focusNode: _fUser,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _fPw.requestFocus(),
              decoration: const InputDecoration(labelText: 'Username')),
          TextField(
            controller: p,
            focusNode: _fPw,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _fCode.requestFocus(),
          ),
          TextField(
              controller: c,
              focusNode: _fCode,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) async {
                if (busy) return;
                setState(() => busy = true);
                await widget.onSubmit(u.text, p.text, c.text, remember);
                setState(() => busy = false);
              },
              decoration:
                  const InputDecoration(labelText: '6-digit TOTP code')),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: remember,
            onChanged: (v) => setState(() => remember = v ?? false),
            title: const Text('Remember me'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          Row(children: [
            ElevatedButton(
                style: ElevatedButton.styleFrom(shape: const StadiumBorder()),
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        await widget.onSubmit(u.text, p.text, c.text, remember);
                        setState(() => busy = false);
                      },
                child: const Text('Login')),
            const Spacer(),
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Reset account?'),
                    content: const Text(
                        'This will delete the current account. You will set up a new username, password, and TOTP. Continue?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Reset')),
                    ],
                  ),
                );
                if (ok == true) widget.onReset();
              },
              child: const Text('Delete account & start fresh'),
            ),
          ]),
          if (widget.msg.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(widget.msg,
                    style: const TextStyle(color: Colors.redAccent))),
        ],
      );
}

class _CardShell extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _CardShell({required this.title, required this.children});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(title,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 12),
                      ...children,
                    ]),
              ),
            ),
          ),
        ),
      );
}
