import 'models.dart';

// Neutral placeholders shown only until the signed-in account's profile loads.
const fieldOfficer = Officer(
  name: 'Field Officer', officerId: '', role: AppRole.field, roleLabel: 'Field Officer',
  department: '', region: '', phone: '', email: '', lastLogin: '',
);

const riderOfficer = Officer(
  name: 'Logistics Rider', officerId: '', role: AppRole.rider, roleLabel: 'Logistics Rider',
  department: '', region: '', phone: '', email: '', lastLogin: '',
);
