// Test-only helper: load a schema straight from the committed Contract-2 file
// (contracts/openapi.yaml) and build a real JSON-Schema validator from it, so
// payload tests validate against the actual contract rather than a hand-copy.
//
// The contract is declared openapi 3.1 but uses the OpenAPI `nullable: true`
// spelling; JSON Schema expresses nullability as a `type: [T, 'null']` union.
// We normalize that one keyword so nullable fields (severity, raw_*) validate.

import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';
import 'package:yaml/yaml.dart';

/// Locates contracts/openapi.yaml relative to the package root (flutter test's
/// cwd is `app/`, the contract lives one level up).
File contractFile() {
  final candidates = <String>[
    '../contracts/openapi.yaml',
    'contracts/openapi.yaml',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  throw StateError(
    'contracts/openapi.yaml not found from ${Directory.current.path}',
  );
}

/// The raw (JSON-normalized) map for a named schema under components.schemas.
Map<String, dynamic> contractSchemaMap(String schemaName) {
  final doc = loadYaml(contractFile().readAsStringSync());
  // Deep-convert YamlMap/YamlList to plain JSON structures.
  final plain = json.decode(json.encode(doc)) as Map<String, dynamic>;
  final schemas = (plain['components'] as Map)['schemas'] as Map;
  final schema = schemas[schemaName];
  if (schema is! Map) {
    throw StateError('schema "$schemaName" not found in contract');
  }
  return _openApiToJsonSchema(Map<String, dynamic>.from(schema));
}

/// A JSON-Schema validator for a named contract schema (draft 2020-12, the
/// dialect OpenAPI 3.1 aligns with).
JsonSchema contractValidator(String schemaName) => JsonSchema.create(
      contractSchemaMap(schemaName),
      schemaVersion: SchemaVersion.draft2020_12,
    );

/// The declared property names for a contract schema.
Set<String> contractPropertyNames(String schemaName) {
  final props = contractSchemaMap(schemaName)['properties'];
  return props is Map ? props.keys.map((k) => k.toString()).toSet() : <String>{};
}

Map<String, dynamic> _openApiToJsonSchema(Map<String, dynamic> schema) {
  final out = Map<String, dynamic>.from(schema);
  final props = out['properties'];
  if (props is Map) {
    out['properties'] = <String, dynamic>{
      for (final entry in props.entries)
        entry.key.toString():
            _normalizeProperty(Map<String, dynamic>.from(entry.value as Map)),
    };
  }
  return out;
}

Map<String, dynamic> _normalizeProperty(Map<String, dynamic> property) {
  final out = Map<String, dynamic>.from(property);
  // OpenAPI `nullable: true` → JSON-Schema null-union on `type`.
  if (out['nullable'] == true && out['type'] is String) {
    out['type'] = <String>[out['type'] as String, 'null'];
  }
  out.remove('nullable');
  return out;
}
