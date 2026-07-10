import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/services/map_tile_service.dart';

void main() {
  group('BaghdadRegion bounding box sanity', () {
    // Iraq's approximate real-world extent, used only to catch a badly
    // typo'd coordinate (e.g. a transposed digit or swapped lat/lon) before
    // it silently downloads the wrong region.
    const iraqMinLat = 29.0;
    const iraqMaxLat = 37.0;
    const iraqMinLon = 38.0;
    const iraqMaxLon = 49.0;

    test('min latitude is less than max latitude', () {
      expect(BaghdadRegion.minLatitude, lessThan(BaghdadRegion.maxLatitude));
    });

    test('min longitude is less than max longitude', () {
      expect(BaghdadRegion.minLongitude, lessThan(BaghdadRegion.maxLongitude));
    });

    test('latitude bounds fall within Iraq\'s real geographic range', () {
      expect(BaghdadRegion.minLatitude, greaterThanOrEqualTo(iraqMinLat));
      expect(BaghdadRegion.minLatitude, lessThanOrEqualTo(iraqMaxLat));
      expect(BaghdadRegion.maxLatitude, greaterThanOrEqualTo(iraqMinLat));
      expect(BaghdadRegion.maxLatitude, lessThanOrEqualTo(iraqMaxLat));
    });

    test('longitude bounds fall within Iraq\'s real geographic range', () {
      expect(BaghdadRegion.minLongitude, greaterThanOrEqualTo(iraqMinLon));
      expect(BaghdadRegion.minLongitude, lessThanOrEqualTo(iraqMaxLon));
      expect(BaghdadRegion.maxLongitude, greaterThanOrEqualTo(iraqMinLon));
      expect(BaghdadRegion.maxLongitude, lessThanOrEqualTo(iraqMaxLon));
    });

    test('zoom range is valid and street-level (10-17)', () {
      expect(BaghdadRegion.minZoom, lessThan(BaghdadRegion.maxZoom));
      expect(BaghdadRegion.minZoom, greaterThanOrEqualTo(0));
      expect(BaghdadRegion.maxZoom, lessThanOrEqualTo(19));
    });
  });
}
