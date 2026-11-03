/// Area sizes read from OpenStreetMap polygons (volunteer-mapped; NOT an official or surveyed boundary), retrieved through
/// the Overpass API on 2026-11-04 and computed geodesically. They stand in for the five look-alike placeholder boxes stored
/// for the puroks, and are always shown as unverified until an admin confirms a size for the area.
///
/// A reference is only offered for an area when the OSM feature really is that area; [strongMatch] says whether that is
/// established (same name and the same centre as the stored area) or only a candidate that needs confirmation.
class OsmAreaReference {
  const OsmAreaReference({
    required this.areaName,
    required this.osmRef,
    required this.osmName,
    required this.sizeM2,
    required this.strongMatch,
    required this.note,
  });

  final String areaName;

  /// e.g. `way/407890456`.
  final String osmRef;
  final String osmName;
  final double sizeM2;
  final bool strongMatch;
  final String note;

  static const String retrieved = '2026-11-04';

  String get source => 'OpenStreetMap $osmRef "$osmName" (volunteer-mapped, retrieved $retrieved); ${strongMatch ? 'same name and centre as the stored area' : 'candidate match, confirm with the barangay'}';

  static const List<OsmAreaReference> all = <OsmAreaReference>[
    OsmAreaReference(
      areaName: 'Riverside',
      osmRef: 'way/407890456',
      osmName: 'Riverside Subdivision',
      sizeM2: 62150,
      strongMatch: true,
      note: 'The OSM centre (13.94654, 121.16365) is the stored Riverside coordinate (13.9465, 121.1637). The stored box is 431,995 m².',
    ),
    OsmAreaReference(
      areaName: 'Brixton Homes',
      osmRef: 'relation/18115151',
      osmName: 'Brixton Heights',
      sizeM2: 37956,
      strongMatch: false,
      note: 'Name differs (Heights vs Homes) and the OSM centre is about 190 m from the stored point; it may be the same subdivision. The stored box is 431,979 m².',
    ),
  ];

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static OsmAreaReference? forArea(String name) {
    final String n = _norm(name);
    for (final OsmAreaReference r in all) {
      if (_norm(r.areaName) == n) return r;
    }
    return null;
  }
}
