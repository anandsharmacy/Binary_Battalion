import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase/supabase_providers.dart';
import '../../mock_data/models.dart';
import '../../mock_data/mock_officers.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../shared/motion.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/ner_toggle.dart';

/// ProfileSheet — slides up from the bottom over any screen.
/// Two tabs: Profile (read-only info) + Settings (5 accordion sections).
/// Matches React ProfileScreen exactly — same sections, same field order.
class ProfileSheet extends ConsumerStatefulWidget {
  final AppRole role;
  final VoidCallback onClose;
  final VoidCallback onSignOut;

  /// Real account data from Supabase; falls back to a neutral placeholder for
  /// the role when not signed in (e.g. widget tests).
  final Officer? officer;

  const ProfileSheet({
    super.key,
    required this.role,
    required this.onClose,
    required this.onSignOut,
    this.officer,
  });

  @override
  ConsumerState<ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends ConsumerState<ProfileSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  // ── Settings accordion state ──────────────────────────────────────
  String? _openSection; // 'edit' | 'notifications' | 'language' | 'security'

  // Edit profile
  late String _editName;
  late String _editPhone;
  late String _editEmail;
  bool _avatarUploaded = false;

  // Notifications: public.notification_prefs (own row). Defaults match the table's.
  bool _notifPush = true;
  bool _notifEmail = true;
  bool _notifSms = false;
  String? _saveError;

  // Language
  String _language = 'en';

  // Security
  bool _twoFa = true;

  // Save states
  String _editSave = 'idle'; // idle | saving | saved
  String _notifSave = 'idle';
  String _langSave = 'idle';

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    final o = _officer;
    _editName = o.name;
    _editPhone = o.phone;
    _editEmail = o.email;
    _loadPrefs();
  }

  /// Null when there is no Supabase client or nobody is signed in (e.g. widget tests).
  SupabaseClient? get _client {
    try {
      final c = ref.read(supabaseClientProvider);
      return c.auth.currentUser == null ? null : c;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadPrefs() async {
    final c = _client;
    if (c == null) return;
    try {
      final row = await c
          .from('notification_prefs')
          .select('push,email,sms')
          .maybeSingle();
      if (row != null && mounted) {
        setState(() {
          _notifPush = row['push'] == true;
          _notifEmail = row['email'] == true;
          _notifSms = row['sms'] == true;
        });
      }
    } catch (_) {
      // Keep defaults; saving reports any real error.
    }
  }

  /// Runs [op] with the idle -> saving -> saved|idle states; shows the error on failure.
  Future<void> _save(String field, Future<void> Function() op) async {
    void mark(String v) {
      if (field == 'edit') _editSave = v;
      if (field == 'notif') _notifSave = v;
      if (field == 'lang') _langSave = v;
    }

    setState(() {
      mark('saving');
      _saveError = null;
    });
    try {
      await op();
      if (!mounted) return;
      setState(() => mark('saved'));
      await Future.delayed(const Duration(milliseconds: 2500));
      if (mounted) setState(() => mark('idle'));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        mark('idle');
        _saveError = e is PostgrestException ? e.message : '$e';
      });
    }
  }

  Future<void> _saveProfile() async {
    final c = _client;
    if (c == null) throw 'Sign in to save your profile.';
    await c
        .from('profiles')
        .update({'full_name': _editName.trim(), 'phone': _editPhone.trim()})
        .eq('id', c.auth.currentUser!.id);
    final email = _editEmail.trim();
    if (email.isNotEmpty && email != c.auth.currentUser!.email) {
      // Supabase sends a confirmation link; the address changes once it is opened.
      await c.auth.updateUser(UserAttributes(email: email));
    }
  }

  Future<void> _saveNotifPrefs() async {
    final c = _client;
    if (c == null) throw 'Sign in to save notification preferences.';
    await c.from('notification_prefs').upsert({
      'user_id': c.auth.currentUser!.id,
      'push': _notifPush,
      'email': _notifEmail,
      'sms': _notifSms,
    });
  }

  // ponytail: the choice is stored on this device only; the app locale doesn't switch yet.
  Future<void> _saveLanguage() async => (await SharedPreferences.getInstance())
      .setString('app_language', _language);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Officer get _officer {
    final real = widget.officer;
    if (real != null) return real;
    switch (widget.role) {
      case AppRole.field:
        return fieldOfficer;
      case AppRole.rider:
        return riderOfficer;
    }
  }

  void _toggleSection(String key) =>
      setState(() => _openSection = _openSection == key ? null : key);

  @override
  Widget build(BuildContext context) {
    final o = _officer;
    // BlockSemantics keeps VoiceOver/TalkBack inside the sheet.
    final scrim = ModalBarrier(
      color: Colors.black.withOpacity(0.50),
      onDismiss: widget.onClose,
      semanticsLabel: 'Close profile',
    );
    final highContrast = MediaQuery.highContrastOf(context);
    return BlockSemantics(
      child: Stack(
        children: [
          highContrast
              ? scrim
              : BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: AppColors.glassBlurSigmaChrome,
                    sigmaY: AppColors.glassBlurSigmaChrome,
                  ),
                  child: scrim,
                ),
          Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.95,
              ),
              child: GlassSurface(
                tint: AppColors.paper,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Drag handle
                    Container(
                      margin: const EdgeInsets.only(top: 12, bottom: 4),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFC4C8CD),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // Navy profile header
                    _ProfileHeader(
                      officer: o,
                      avatarUploaded: _avatarUploaded,
                      onClose: widget.onClose,
                      onCameraToggle: () =>
                          setState(() => _avatarUploaded = !_avatarUploaded),
                    ),
                    // Account status bar
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          bottom: BorderSide(color: AppColors.hairline),
                        ),
                      ),
                      child: Row(
                        children: [
                          Text('Account Status', style: AppTextStyles.caption),
                          const Spacer(),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: AppColors.deepGreen700,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Active · Verified',
                            style: AppTextStyles.captionSemibold.copyWith(
                              color: AppColors.deepGreen700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Tab bar
                    Container(
                      color: Colors.white,
                      child: TabBar(
                        controller: _tab,
                        tabs: const [
                          Tab(text: 'Profile'),
                          Tab(text: 'Settings'),
                        ],
                      ),
                    ),
                    // Tab content
                    Flexible(
                      child: TabBarView(
                        controller: _tab,
                        children: [
                          _ProfileTab(
                            officer: o,
                            onEditTap: () {
                              _tab.animateTo(1);
                              _toggleSection('edit');
                            },
                          ),
                          _SettingsTab(
                            openSection: _openSection,
                            onToggle: _toggleSection,
                            // Edit
                            editName: _editName,
                            editPhone: _editPhone,
                            editEmail: _editEmail,
                            avatarUploaded: _avatarUploaded,
                            editSave: _editSave,
                            onEditName: (v) => setState(() => _editName = v),
                            onEditPhone: (v) => setState(() => _editPhone = v),
                            onEditEmail: (v) => setState(() => _editEmail = v),
                            onAvatarToggle: () => setState(
                              () => _avatarUploaded = !_avatarUploaded,
                            ),
                            onSaveProfile: () => _save('edit', _saveProfile),
                            // Notifications
                            notifPush: _notifPush,
                            notifEmail: _notifEmail,
                            notifSms: _notifSms,
                            notifSave: _notifSave,
                            saveError: _saveError,
                            onToggleNotif: (key) => setState(() {
                              switch (key) {
                                case 'push':
                                  _notifPush = !_notifPush;
                                  break;
                                case 'email':
                                  _notifEmail = !_notifEmail;
                                  break;
                                case 'sms':
                                  _notifSms = !_notifSms;
                                  break;
                              }
                            }),
                            onSaveNotif: () => _save('notif', _saveNotifPrefs),
                            // Language
                            language: _language,
                            langSave: _langSave,
                            onLanguage: (v) => setState(() => _language = v),
                            onApplyLanguage: () => _save('lang', _saveLanguage),
                            // Security
                            twoFa: _twoFa,
                            onTwoFa: (v) => setState(() => _twoFa = v),
                            // Sign out
                            onSignOut: widget.onSignOut,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Profile header (navy bg) ─────────────────────────────────────────────────
class _ProfileHeader extends StatelessWidget {
  final Officer officer;
  final bool avatarUploaded;
  final VoidCallback onClose;
  final VoidCallback onCameraToggle;

  const _ProfileHeader({
    required this.officer,
    required this.avatarUploaded,
    required this.onClose,
    required this.onCameraToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.navy900,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 16),
      child: Row(
        children: [
          // Avatar with camera overlay
          Stack(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: avatarUploaded
                      ? AppColors.gold
                      : Colors.white.withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 2,
                  ),
                ),
                alignment: Alignment.center,
                child: avatarUploaded
                    ? Text(
                        officer.initials,
                        style: AppTextStyles.statValue.copyWith(
                          color: AppColors.navy900,
                          fontSize: 22,
                        ),
                      )
                    : const Icon(
                        Icons.person_outline,
                        size: 28,
                        color: Colors.white,
                      ),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: Semantics(
                  button: true,
                  label: 'Change profile photo',
                  onTap: onCameraToggle,
                  excludeSemantics: true,
                  // 22 pt badge, 48 pt hit area (HIG accessibility.md).
                  child: SizedBox.square(
                    dimension: kMinInteractiveDimension,
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        onTap: onCameraToggle,
                        customBorder: const CircleBorder(),
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.camera_alt_outlined,
                              size: 12,
                              color: AppColors.navy900,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  officer.name,
                  style: AppTextStyles.sectionHeading.copyWith(
                    color: Colors.white,
                    fontSize: 18,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  officer.officerId,
                  style: AppTextStyles.caption.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.gold.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.gold.withOpacity(0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: AppColors.gold,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        officer.roleLabel,
                        style: AppTextStyles.eyebrow.copyWith(
                          color: AppColors.gold,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 18),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

// ── Profile tab ───────────────────────────────────────────────────────────────
class _ProfileTab extends StatelessWidget {
  final Officer officer;
  final VoidCallback onEditTap;

  const _ProfileTab({required this.officer, required this.onEditTap});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(label: 'Officer Information'),
          _InfoTable(
            rows: [
              _InfoRow('Full Name', officer.name),
              _InfoRow('Officer ID', officer.officerId),
              _InfoRow('Role', officer.roleLabel),
              _InfoRow('Department', officer.department),
              _InfoRow('District / Region', officer.region),
            ],
          ),
          _SectionHeader(label: 'Contact Details'),
          _InfoTable(
            rows: [
              _InfoRow('Phone', officer.phone),
              _InfoRow('Email', officer.email),
            ],
          ),
          _SectionHeader(label: 'Session'),
          _InfoTable(
            rows: [
              _InfoRow('Last Login', officer.lastLogin),
              _InfoRow('Connectivity', '4G Online'),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onEditTap,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit Profile'),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoTable extends StatelessWidget {
  final List<_InfoRow> rows;
  const _InfoTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        children: rows
            .asMap()
            .entries
            .map(
              (e) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  border: e.key < rows.length - 1
                      ? Border(bottom: BorderSide(color: AppColors.hairline))
                      : null,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(
                        e.value.label,
                        style: AppTextStyles.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        e.value.value,
                        style: AppTextStyles.bodySmallMedium.copyWith(
                          textBaseline: TextBaseline.alphabetic,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _InfoRow {
  final String label, value;
  const _InfoRow(this.label, this.value);
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8, left: 4),
    child: Text(
      label.toUpperCase(),
      style: AppTextStyles.eyebrow.copyWith(color: AppColors.slate500),
    ),
  );
}

// ── Settings tab ──────────────────────────────────────────────────────────────
class _SettingsTab extends StatelessWidget {
  final String? openSection;
  final ValueChanged<String> onToggle;

  // Edit
  final String editName, editPhone, editEmail;
  final bool avatarUploaded;
  final String editSave;
  final ValueChanged<String> onEditName, onEditPhone, onEditEmail;
  final VoidCallback onAvatarToggle, onSaveProfile;

  // Notifications
  final bool notifPush, notifEmail, notifSms;
  final String notifSave;
  final String? saveError;
  final ValueChanged<String> onToggleNotif;
  final VoidCallback onSaveNotif;

  // Language
  final String language, langSave;
  final ValueChanged<String> onLanguage;
  final VoidCallback onApplyLanguage;

  // Security
  final bool twoFa;
  final ValueChanged<bool> onTwoFa;

  final VoidCallback onSignOut;

  const _SettingsTab({
    required this.openSection,
    required this.onToggle,
    required this.editName,
    required this.editPhone,
    required this.editEmail,
    required this.avatarUploaded,
    required this.editSave,
    required this.onEditName,
    required this.onEditPhone,
    required this.onEditEmail,
    required this.onAvatarToggle,
    required this.onSaveProfile,
    required this.notifPush,
    required this.notifEmail,
    required this.notifSms,
    required this.notifSave,
    required this.saveError,
    required this.onToggleNotif,
    required this.onSaveNotif,
    required this.language,
    required this.langSave,
    required this.onLanguage,
    required this.onApplyLanguage,
    required this.twoFa,
    required this.onTwoFa,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      child: Column(
        children: [
          if (saveError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Not saved: $saveError',
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.signalRed700,
                ),
              ),
            ),
          // 1 · Edit Profile
          _AccordionSection(
            icon: Icons.edit_outlined,
            label: 'Edit Profile',
            isOpen: openSection == 'edit',
            onToggle: () => onToggle('edit'),
            child: _EditProfileBody(
              name: editName,
              phone: editPhone,
              email: editEmail,
              saveState: editSave,
              onName: onEditName,
              onPhone: onEditPhone,
              onEmail: onEditEmail,
              onSave: onSaveProfile,
            ),
          ),
          const SizedBox(height: 10),
          // 2 · Notifications
          _AccordionSection(
            icon: Icons.notifications_outlined,
            label: 'Notifications',
            isOpen: openSection == 'notifications',
            onToggle: () => onToggle('notifications'),
            child: _NotificationsBody(
              push: notifPush,
              email: notifEmail,
              sms: notifSms,
              saveState: notifSave,
              onToggle: onToggleNotif,
              onSave: onSaveNotif,
            ),
          ),
          const SizedBox(height: 10),
          // 4 · Language
          _AccordionSection(
            icon: Icons.language_outlined,
            label: 'Language',
            isOpen: openSection == 'language',
            onToggle: () => onToggle('language'),
            child: _LanguageBody(
              language: language,
              saveState: langSave,
              onLanguage: onLanguage,
              onApply: onApplyLanguage,
            ),
          ),
          const SizedBox(height: 10),
          // 5 · Security
          _AccordionSection(
            icon: Icons.shield_outlined,
            label: 'Security & Password',
            isOpen: openSection == 'security',
            onToggle: () => onToggle('security'),
            child: _SecurityBody(twoFa: twoFa, onTwoFa: onTwoFa),
          ),
          const SizedBox(height: 24),
          // Sign out
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onSignOut,
              icon: const Icon(Icons.logout_outlined, size: 16),
              label: const Text('Sign out'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.signalRed700,
                side: BorderSide(
                  color: AppColors.signalRed700.withOpacity(0.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Accordion section wrapper ────────────────────────────────────────────────
class _AccordionSection extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isOpen;
  final VoidCallback onToggle;
  final Widget child;

  const _AccordionSection({
    required this.icon,
    required this.label,
    required this.isOpen,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: isOpen
                ? const BorderRadius.vertical(top: Radius.circular(6))
                : BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isOpen ? AppColors.navy900 : AppColors.paper,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      icon,
                      size: 17,
                      color: isOpen
                          ? Colors.white
                          : AppColors.navy900.withOpacity(0.7),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(label, style: AppTextStyles.cardTitle)),
                  AnimatedRotation(
                    turns: isOpen ? 0.5 : 0,
                    duration: motion(
                      context,
                      const Duration(milliseconds: 200),
                    ),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 20,
                      color: AppColors.slate500.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: motion(context, const Duration(milliseconds: 240)),
            curve: Curves.easeOut,
            child: isOpen
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: AppColors.hairline),
                      ),
                    ),
                    child: child,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ── Edit Profile body ────────────────────────────────────────────────────────
class _EditProfileBody extends StatelessWidget {
  final String name, phone, email, saveState;
  final ValueChanged<String> onName, onPhone, onEmail;
  final VoidCallback onSave;

  const _EditProfileBody({
    required this.name,
    required this.phone,
    required this.email,
    required this.saveState,
    required this.onName,
    required this.onPhone,
    required this.onEmail,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        _SettingsField(label: 'Full Name', value: name, onChanged: onName),
        _SettingsField(
          label: 'Phone',
          value: phone,
          onChanged: onPhone,
          keyboardType: TextInputType.phone,
        ),
        _SettingsField(
          label: 'Email',
          value: email,
          onChanged: onEmail,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: saveState == 'saving' ? null : onSave,
            child: saveState == 'saving'
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : Text(
                    saveState == 'saved' ? 'Profile updated' : 'Save Changes',
                  ),
          ),
        ),
      ],
    );
  }
}

// ── Notifications body ───────────────────────────────────────────────────────
class _NotificationsBody extends StatelessWidget {
  final bool push, email, sms;
  final String saveState;
  final ValueChanged<String> onToggle;
  final VoidCallback onSave;

  const _NotificationsBody({
    required this.push,
    required this.email,
    required this.sms,
    required this.saveState,
    required this.onToggle,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        'push',
        'Push Notifications',
        'Alerts on this phone (moderate and above)',
        push,
      ),
      (
        'email',
        'Email Notifications',
        'High and critical alerts to your email',
        email,
      ),
      (
        'sms',
        'SMS Notifications',
        'Critical alerts to your registered mobile',
        sms,
      ),
    ];
    return Column(
      children: [
        const SizedBox(height: 8),
        for (final item in items)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: item == items.last
                      ? Colors.transparent
                      : AppColors.hairline,
                ),
              ),
            ),
            child: MergeSemantics(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.$2, style: AppTextStyles.bodySmallMedium),
                        Text(
                          item.$3,
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.slate500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  NerToggle(
                    value: item.$4,
                    onChanged: (_) => onToggle(item.$1),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: saveState == 'saving' ? null : onSave,
            child: saveState == 'saving'
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : Text(
                    saveState == 'saved'
                        ? 'Preferences saved'
                        : 'Save Preferences',
                  ),
          ),
        ),
      ],
    );
  }
}

// ── Language body ─────────────────────────────────────────────────────────────
class _LanguageBody extends StatelessWidget {
  final String language, saveState;
  final ValueChanged<String> onLanguage;
  final VoidCallback onApply;

  const _LanguageBody({
    required this.language,
    required this.saveState,
    required this.onLanguage,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final langs = [
      ('en', 'English', 'English'),
      ('hi', 'हिन्दी', 'Hindi'),
      ('as', 'অসমীয়া', 'Assamese'),
      ('bn', 'বাংলা', 'Bengali'),
      ('brx', 'बड़ो', 'Bodo'),
      ('kha', 'Khasi', 'Khasi'),
    ];
    return Column(
      children: [
        const SizedBox(height: 8),
        for (final l in langs)
          InkWell(
            onTap: () => onLanguage(l.$1),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: l.$1 != langs.last.$1
                        ? AppColors.hairline
                        : Colors.transparent,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.$2, style: AppTextStyles.bodySmallMedium),
                        Text(
                          l.$3,
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.slate500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (language == l.$1)
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: AppColors.deepGreen700,
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: saveState == 'saving' ? null : onApply,
            child: saveState == 'saving'
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : Text(
                    saveState == 'saved'
                        ? 'Language applied'
                        : 'Apply Language',
                  ),
          ),
        ),
      ],
    );
  }
}

// ── Security body ─────────────────────────────────────────────────────────────
class _SecurityBody extends StatelessWidget {
  final bool twoFa;
  final ValueChanged<bool> onTwoFa;

  const _SecurityBody({required this.twoFa, required this.onTwoFa});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.paper,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.hairline),
          ),
          child: MergeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Two-Factor Authentication',
                        style: AppTextStyles.bodySmallMedium,
                      ),
                      Text(
                        'OTP via registered mobile',
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.slate500,
                        ),
                      ),
                    ],
                  ),
                ),
                NerToggle(value: twoFa, onChanged: onTwoFa),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'CHANGE PASSWORD',
          style: AppTextStyles.eyebrow.copyWith(color: AppColors.slate500),
        ),
        const SizedBox(height: 8),
        _SettingsField(
          label: 'Current Password',
          value: '',
          onChanged: (_) {},
          obscure: true,
        ),
        _SettingsField(
          label: 'New Password (min. 8 characters)',
          value: '',
          onChanged: (_) {},
          obscure: true,
        ),
        _SettingsField(
          label: 'Confirm New Password',
          value: '',
          onChanged: (_) {},
          obscure: true,
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () {},
            child: const Text('Change Password'),
          ),
        ),
      ],
    );
  }
}

// ── Shared settings form field ────────────────────────────────────────────────
class _SettingsField extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final TextInputType keyboardType;
  final bool obscure;

  const _SettingsField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.keyboardType = TextInputType.text,
    this.obscure = false,
  });

  @override
  State<_SettingsField> createState() => _SettingsFieldState();
}

class _SettingsFieldState extends State<_SettingsField> {
  late final TextEditingController _ctrl;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.label,
            style: AppTextStyles.caption.copyWith(color: AppColors.slate500),
          ),
          const SizedBox(height: 4),
          TextFormField(
            controller: _ctrl,
            onChanged: widget.onChanged,
            keyboardType: widget.keyboardType,
            obscureText: widget.obscure && !_show,
            style: AppTextStyles.inputText,
            decoration: InputDecoration(
              suffixIcon: widget.obscure
                  ? IconButton(
                      icon: Icon(
                        _show
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 18,
                        color: AppColors.slate500,
                      ),
                      onPressed: () => setState(() => _show = !_show),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
