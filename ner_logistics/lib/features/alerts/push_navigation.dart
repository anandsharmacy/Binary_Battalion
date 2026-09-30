import 'package:flutter/foundation.dart';

/// Bumped whenever the rider taps a "new shipment" push notification (app was
/// backgrounded or terminated), so [RiderShell] can jump straight to
/// Deliveries. A plain [ValueNotifier], not a Riverpod provider: it is set
/// from `push_registration.dart`, which runs before any `ProviderContainer`
/// exists (it is started right after `runApp`, outside the widget tree).
final ValueNotifier<int> riderShipmentTapSignal = ValueNotifier(0);
