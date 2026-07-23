import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truxon_companion/services/api.dart';
import 'package:truxon_companion/services/offline_brain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  DriverLoad load(int id, String number, String status) => DriverLoad({
        'id': id,
        'load_number': number,
        'status': status,
        'pickup_address': '100 Dock St, Chicago, IL',
        'delivery_address': '55 Ramp Rd, Denver, CO',
        'customer_name': 'Acme Foods',
      });

  test('status phrase queues an update against the cached active load', () async {
    await OfflineBrain.cacheLoads([load(7, 'L-1007', 'in_transit')]);
    final reply = await OfflineBrain.handle("we're empty, dropped the trailer");
    expect(reply, contains('L-1007'));
    expect(reply.toLowerCase(), contains('dead zone'));
    expect(await OfflineBrain.pendingCount(), 1);
  });

  test('next-stop question reads the cache without queueing anything', () async {
    await OfflineBrain.cacheLoads([load(7, 'L-1007', 'assigned')]);
    final reply = await OfflineBrain.handle('where am I headed');
    expect(reply, contains('Ramp Rd'));
    expect(reply, contains('Acme Foods'));
    expect(await OfflineBrain.pendingCount(), 0);
  });

  test('delivered loads are not treated as the active load', () async {
    await OfflineBrain.cacheLoads([load(3, 'L-0999', 'delivered')]);
    final reply = await OfflineBrain.handle('arrived at the receiver');
    expect(reply.toLowerCase(), contains('no cached load'));
    expect(await OfflineBrain.pendingCount(), 1); // words still saved
  });

  test('anything unrecognized becomes a saved note, never a dead end', () async {
    final reply = await OfflineBrain.handle(
        'tell dispatch the reefer is running warm on this one');
    expect(reply.toLowerCase(), contains('wrote it down'));
    expect(await OfflineBrain.pendingCount(), 1);
  });
}
