// The tools of the harness as `tools/list` describes them: the name a model
// calls each by, the label people read, the permission class, and
// `coalescable`, the allow list of the calls a chat may fold into a run under
// one summary line.
//
// The list is `harness_tools.json`, and it is the harness's own: the
// registry as the Emacs side loads it, so that the app is tried against the
// allow list that is really served and not one made up here.  A suite on the
// Emacs side (test/harness-client-tools-test.el) fails when a tool of the file
// is not as the registry has it, and says how to write the file again.

import 'dart:convert';
import 'dart:io';

/// The specs `tools/list` answers with, as the wire has them.  Tests run in
/// the package's directory, which is where the file is found from.
List<Map<String, Object?>> harnessToolSpecs() {
  final wire = jsonDecode(
    File('test/support/harness_tools.json').readAsStringSync(),
  );
  return [
    for (final spec in wire as List)
      Map<String, Object?>.from(spec as Map<String, dynamic>),
  ];
}

/// The names of the tools on the allow list, as the file has them.
Set<String> harnessFoldableTools() => {
  for (final spec in harnessToolSpecs())
    if (spec['coalescable'] == true) spec['name'] as String,
};
