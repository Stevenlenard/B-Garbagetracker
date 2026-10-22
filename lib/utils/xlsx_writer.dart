import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Cell style of a minimal .xlsx workbook (index into the styles written by [XlsxWorkbook]).
enum XlsxStyle { normal, header, title, subtitle, wrap, bold }

class XlsxCell {
  const XlsxCell(this.value, [this.style = XlsxStyle.normal]);
  final Object? value; // String, num or null
  final XlsxStyle style;
}

class XlsxSheet {
  XlsxSheet(this.name, {this.columnWidths = const <double>[]});
  final String name;
  final List<double> columnWidths; // in Excel character units
  final List<List<XlsxCell>> rows = <List<XlsxCell>>[];
  final List<String> merges = <String>[]; // e.g. 'A1:D1'

  void add(List<Object?> values, [XlsxStyle style = XlsxStyle.normal]) =>
      rows.add(<XlsxCell>[for (final Object? v in values) v is XlsxCell ? v : XlsxCell(v, style)]);

  void blank() => rows.add(const <XlsxCell>[]);
}

/// Writes a real Office Open XML workbook (.xlsx) without any plug-in, so it works the same on
/// the web and on Android and opens in Excel, Google Sheets and phone viewers without warnings.
class XlsxWorkbook {
  final List<XlsxSheet> sheets = <XlsxSheet>[];

  XlsxSheet sheet(String name, {List<double> columnWidths = const <double>[]}) {
    final XlsxSheet s = XlsxSheet(_safeName(name), columnWidths: columnWidths);
    sheets.add(s);
    return s;
  }

  static String _safeName(String n) {
    final String s = n.replaceAll(RegExp(r'[\[\]\*\?/\\:]'), ' ').trim();
    return s.length > 31 ? s.substring(0, 31) : (s.isEmpty ? 'Sheet' : s);
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      // characters that XML 1.0 does not allow
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  static String colName(int index) {
    String s = '';
    int n = index + 1;
    while (n > 0) {
      final int m = (n - 1) % 26;
      s = String.fromCharCode(65 + m) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  String _sheetXml(XlsxSheet s) {
    final StringBuffer b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
    if (s.columnWidths.isNotEmpty) {
      b.write('<cols>');
      for (int i = 0; i < s.columnWidths.length; i++) {
        b.write('<col min="${i + 1}" max="${i + 1}" width="${s.columnWidths[i]}" customWidth="1"/>');
      }
      b.write('</cols>');
    }
    b.write('<sheetData>');
    for (int r = 0; r < s.rows.length; r++) {
      b.write('<row r="${r + 1}">');
      final List<XlsxCell> row = s.rows[r];
      for (int c = 0; c < row.length; c++) {
        final XlsxCell cell = row[c];
        final String ref = '${colName(c)}${r + 1}';
        final int st = cell.style.index;
        final Object? v = cell.value;
        if (v == null || (v is String && v.isEmpty)) {
          if (st != 0) b.write('<c r="$ref" s="$st"/>');
        } else if (v is num && v.isFinite) {
          b.write('<c r="$ref" s="$st"><v>$v</v></c>');
        } else {
          b.write('<c r="$ref" s="$st" t="inlineStr"><is><t xml:space="preserve">${_esc(v.toString())}</t></is></c>');
        }
      }
      b.write('</row>');
    }
    b.write('</sheetData>');
    if (s.merges.isNotEmpty) {
      b.write('<mergeCells count="${s.merges.length}">');
      for (final String m in s.merges) {
        b.write('<mergeCell ref="$m"/>');
      }
      b.write('</mergeCells>');
    }
    b.write('</worksheet>');
    return b.toString();
  }

  // Style order must match XlsxStyle: normal, header, title, subtitle, wrap, bold.
  static const String _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="5">'
      '<font><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>'
      '<font><b/><sz val="16"/><color rgb="FF00695C"/><name val="Calibri"/></font>'
      '<font><b/><sz val="12"/><color rgb="FF004D40"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/></font>'
      '</fonts>'
      '<fills count="3">'
      '<fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FF00796B"/><bgColor indexed="64"/></patternFill></fill>'
      '</fills>'
      '<borders count="2">'
      '<border><left/><right/><top/><bottom/><diagonal/></border>'
      '<border><left style="thin"><color rgb="FFD1D5DB"/></left><right style="thin"><color rgb="FFD1D5DB"/></right>'
      '<top style="thin"><color rgb="FFD1D5DB"/></top><bottom style="thin"><color rgb="FFD1D5DB"/></bottom><diagonal/></border>'
      '</borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="6">'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"><alignment vertical="top"/></xf>'
      '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"><alignment vertical="center" wrapText="1"/></xf>'
      '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>'
      '<xf numFmtId="0" fontId="4" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"><alignment vertical="top"/></xf>'
      '</cellXfs>'
      '</styleSheet>';

  Uint8List build() {
    if (sheets.isEmpty) sheet('Sheet1');
    final Archive a = Archive();
    void put(String name, String content) {
      final List<int> bytes = utf8.encode(content);
      a.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    final StringBuffer types = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
      ..write('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
      ..write('<Default Extension="xml" ContentType="application/xml"/>')
      ..write('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
      ..write('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>');
    for (int i = 0; i < sheets.length; i++) {
      types.write('<Override PartName="/xl/worksheets/sheet${i + 1}.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
    }
    types.write('</Types>');
    put('[Content_Types].xml', types.toString());
    put('_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>');

    final StringBuffer wb = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>');
    final StringBuffer rels = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">');
    final Set<String> used = <String>{};
    for (int i = 0; i < sheets.length; i++) {
      String name = sheets[i].name;
      int k = 2;
      while (!used.add(name.toLowerCase())) {
        name = '${sheets[i].name.substring(0, sheets[i].name.length.clamp(0, 28))} $k';
        k++;
      }
      wb.write('<sheet name="${_esc(name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>');
      rels.write('<Relationship Id="rId${i + 1}" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
          'Target="worksheets/sheet${i + 1}.xml"/>');
      put('xl/worksheets/sheet${i + 1}.xml', _sheetXml(sheets[i]));
    }
    wb.write('</sheets></workbook>');
    rels.write('<Relationship Id="rId${sheets.length + 1}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>');
    rels.write('</Relationships>');
    put('xl/workbook.xml', wb.toString());
    put('xl/_rels/workbook.xml.rels', rels.toString());
    put('xl/styles.xml', _styles);

    return Uint8List.fromList(ZipEncoder().encode(a));
  }
}
