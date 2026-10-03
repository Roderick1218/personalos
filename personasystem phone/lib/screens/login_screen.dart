import 'package:flutter/material.dart';
import '../api_service.dart';
import '../theme.dart';

/// 手机版登录/注册/忘记密码页 —— 跟网站端 index.html 的登录卡片同一套流程:
/// 登录用「邮箱 + 密码」；注册要「名字 + 邮箱 + 密码 + 确认密码」，送出一组邮箱验证码，
/// 输入验证码之后才算注册完成；忘记密码则自己用邮箱验证码把密码重设掉，不需要管理员帮忙。
class LoginScreen extends StatefulWidget {
  final void Function(Map<String, dynamic> user) onLoggedIn;
  const LoginScreen({super.key, required this.onLoggedIn});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _LoginMode { login, register, forgot }

class _LoginScreenState extends State<LoginScreen> {
  _LoginMode _mode = _LoginMode.login;
  bool _otpStep = false;
  bool _submitting = false;
  String? _error;
  String? _hint;

  String _pendingEmail = '';
  String _pendingName = '';

  final _emailCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passwordConfirmCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _newPasswordConfirmCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _displayNameCtrl.dispose();
    _passwordCtrl.dispose();
    _passwordConfirmCtrl.dispose();
    _otpCtrl.dispose();
    _newPasswordCtrl.dispose();
    _newPasswordConfirmCtrl.dispose();
    super.dispose();
  }

  void _switchMode(_LoginMode mode) {
    setState(() {
      _mode = mode;
      _otpStep = false;
      _error = null;
      _hint = null;
      _otpCtrl.clear();
      _newPasswordCtrl.clear();
      _newPasswordConfirmCtrl.clear();
    });
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (_otpStep) {
      if (_mode == _LoginMode.register) return _submitSignupOtp();
      return _submitResetOtp();
    }

    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (email.isEmpty) {
      setState(() => _error = '请填写邮箱');
      return;
    }

    if (_mode == _LoginMode.login) {
      if (password.isEmpty) {
        setState(() => _error = '请填写密码');
        return;
      }
      setState(() => _submitting = true);
      try {
        final user = await ApiService.login(email, password);
        if (user != null) widget.onLoggedIn(user);
      } catch (e) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      } finally {
        if (mounted) setState(() => _submitting = false);
      }
      return;
    }

    if (_mode == _LoginMode.register) {
      if (_displayNameCtrl.text.trim().isEmpty) {
        setState(() => _error = '请填写名字');
        return;
      }
      if (password.length < 6) {
        setState(() => _error = '密码至少要 6 位');
        return;
      }
      if (password != _passwordConfirmCtrl.text) {
        setState(() => _error = '两次输入的密码不一样');
        return;
      }
      setState(() => _submitting = true);
      try {
        final res = await ApiService.register(email, password, _displayNameCtrl.text.trim());
        if (res['needs_otp'] == true) {
          setState(() {
            _pendingEmail = res['email']?.toString() ?? email;
            _pendingName = res['display_name']?.toString() ?? _displayNameCtrl.text.trim();
            _otpStep = true;
            _hint = '验证码已经寄到 $_pendingEmail，请到信箱收信。';
          });
        } else {
          widget.onLoggedIn(res);
        }
      } catch (e) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      } finally {
        if (mounted) setState(() => _submitting = false);
      }
      return;
    }

    // 忘记密码第一步：寄验证码
    setState(() => _submitting = true);
    try {
      await ApiService.requestPasswordReset(email);
      setState(() {
        _pendingEmail = email;
        _otpStep = true;
        _hint = '如果这个邮箱已经注册过，验证码已经寄到 $email。';
      });
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitSignupOtp() async {
    final code = _otpCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请填写验证码');
      return;
    }
    setState(() => _submitting = true);
    try {
      final user = await ApiService.verifySignupOtp(_pendingEmail, code, _pendingName);
      widget.onLoggedIn(user);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitResetOtp() async {
    final code = _otpCtrl.text.trim();
    final pw = _newPasswordCtrl.text;
    if (code.isEmpty) {
      setState(() => _error = '请填写验证码');
      return;
    }
    if (pw.length < 6) {
      setState(() => _error = '新密码至少要 6 位');
      return;
    }
    if (pw != _newPasswordConfirmCtrl.text) {
      setState(() => _error = '两次输入的新密码不一样');
      return;
    }
    setState(() => _submitting = true);
    try {
      await ApiService.resetPasswordWithOtp(_pendingEmail, code, pw);
      if (!mounted) return;
      setState(() {
        _mode = _LoginMode.login;
        _otpStep = false;
        _hint = null;
        _error = '密码已经改好，请用新密码登录。';
        _emailCtrl.text = _pendingEmail;
        _passwordCtrl.clear();
        _otpCtrl.clear();
        _newPasswordCtrl.clear();
        _newPasswordConfirmCtrl.clear();
      });
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String get _subtitle {
    if (_otpStep) return _hint ?? '';
    switch (_mode) {
      case _LoginMode.register:
        return '填写名字、邮箱和密码，我们会寄一组验证码到你的邮箱';
      case _LoginMode.forgot:
        return '输入你注册时用的邮箱，我们会寄一组验证码给你';
      case _LoginMode.login:
        return '用邮箱和密码登录';
    }
  }

  String get _submitLabel {
    if (_otpStep) return _mode == _LoginMode.register ? '验证并开始使用' : '验证并重设密码';
    switch (_mode) {
      case _LoginMode.register:
        return '注册';
      case _LoginMode.forgot:
        return '寄送验证码';
      case _LoginMode.login:
        return '登录';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRegister = _mode == _LoginMode.register;
    final isForgot = _mode == _LoginMode.forgot;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Image.asset('assets/logo.png', width: 72, height: 72),
                const SizedBox(height: 12),
                const Text(
                  '安本',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.text),
                ),
                const SizedBox(height: 6),
                Text(
                  _subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 32),
                if (!_otpStep) ...[
                  if (isRegister) ...[
                    TextField(
                      controller: _displayNameCtrl,
                      decoration: const InputDecoration(labelText: '名字'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: '邮箱'),
                    textInputAction: TextInputAction.next,
                  ),
                  if (!isForgot) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _passwordCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '密码'),
                      textInputAction: isRegister ? TextInputAction.next : TextInputAction.done,
                      onSubmitted: (_) {
                        if (!isRegister) _submit();
                      },
                    ),
                  ],
                  if (isRegister) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _passwordConfirmCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '确认密码'),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                  ],
                ] else ...[
                  TextField(
                    controller: _otpCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '邮箱验证码', hintText: '邮件里的全部数字'),
                    textInputAction: isForgot ? TextInputAction.next : TextInputAction.done,
                    onSubmitted: (_) {
                      if (!isForgot) _submit();
                    },
                  ),
                  if (isForgot) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _newPasswordCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '新密码（至少 6 位）'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _newPasswordConfirmCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '确认新密码'),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                  ],
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 18, width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onAccent),
                        )
                      : Text(_submitLabel),
                ),
                const SizedBox(height: 16),
                if (_otpStep)
                  TextButton(
                    onPressed: _submitting ? null : () => _switchMode(_mode),
                    child: const Text('收不到？点这里回到上一步'),
                  )
                else ...[
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => _switchMode(isRegister ? _LoginMode.login : _LoginMode.register),
                    child: Text(isRegister ? '已经有账号？点这里登录' : '还没有账号？点这里注册'),
                  ),
                  if (!isForgot)
                    TextButton(
                      onPressed: _submitting ? null : () => _switchMode(_LoginMode.forgot),
                      child: const Text('忘记密码？'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
