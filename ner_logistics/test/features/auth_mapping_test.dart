import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ner_logistics/features/auth/data/auth_repository.dart';
import 'package:ner_logistics/features/auth/domain/auth_models.dart';
import 'package:ner_logistics/mock_data/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('AuthRepository.resolveEmail', () {
    test('has no officer-ID shortcuts: IDs are not mapped to accounts', () {
      expect(AuthRepository.resolveEmail('NER-FO-4471'), 'NER-FO-4471');
    });

    test('trims emails and otherwise passes them through', () {
      expect(AuthRepository.resolveEmail(' officer@gov.in '), 'officer@gov.in');
    });
  });

  group('AppRoleDb', () {
    test('round-trips every role', () {
      for (final role in AppRole.values) {
        expect(AppRoleDb.fromDb(role.dbValue), role);
      }
      expect(AppRoleDb.fromDb('nope'), isNull);
      expect(AppRoleDb.fromDb(null), isNull);
    });

    test('rider is the only non-officer role', () {
      expect(AppRole.rider.isOfficer, isFalse);
      expect(AppRole.field.isOfficer, isTrue);
      expect(AppRole.rider.initials, 'RD');
    });
  });

  group('AuthRepository.mapAuthError', () {
    test('invalid credentials', () {
      final f = AuthRepository.mapAuthError(const AuthException('Invalid login credentials'));
      expect(f.kind, AuthFailureKind.invalidCredentials);
    });

    test('email not confirmed', () {
      final f = AuthRepository.mapAuthError(const AuthException('Email not confirmed'));
      expect(f.kind, AuthFailureKind.emailNotConfirmed);
    });

    test('timeouts become network failures', () {
      final f = AuthRepository.mapAuthError(TimeoutException('slow'));
      expect(f.kind, AuthFailureKind.network);
    });

    test('existing AuthFailure passes through', () {
      const original = AuthFailure('x', kind: AuthFailureKind.noRole);
      expect(identical(AuthRepository.mapAuthError(original), original), isTrue);
    });
  });

  test('AuthUserProfile.toOfficer bridges to the legacy Officer model', () {
    const p = AuthUserProfile(
      userId: 'u',
      email: 'p.lyngdoh@ner.gov.in',
      fullName: 'P. Lyngdoh',
      role: AppRole.rider,
      officerId: 'NER-RD-1184',
      districtName: 'Ri Bhoi',
    );
    final o = p.toOfficer();
    expect(o.name, 'P. Lyngdoh');
    expect(o.officerId, 'NER-RD-1184');
    expect(o.roleLabel, 'Logistics Rider');
    expect(o.region, 'Ri Bhoi');
    expect(o.initials, 'RD');
    expect(p.shortName, 'Lyngdoh');
  });
}
