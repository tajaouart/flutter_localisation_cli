/// Resolve a project (by name or id) and flavor so users never hand-type numeric ids.
///
/// Used by both the MCP server and the CLI. Caches the project list from
/// `GET /api/projects/` and picks sensible defaults (the sole project / sole flavor).
library;

import 'package:flutter_localisation_cli/src/exceptions.dart';
import 'package:flutter_localisation_cli/src/management_client.dart';

class ResolvedTarget {
  ResolvedTarget({
    required this.projectId,
    required this.projectName,
    required this.flavor,
  });

  final int projectId;
  final String projectName;
  final String? flavor;
}

class ProjectResolver {
  ProjectResolver(
    this.client, {
    this.defaultProject,
    this.defaultFlavor,
  });

  final ManagementClient client;

  /// A project name or id (as a string) to fall back to when a call omits one.
  final String? defaultProject;
  final String? defaultFlavor;

  List<ProjectSummary>? _cache;

  Future<List<ProjectSummary>> projects({final bool refresh = false}) async {
    if (_cache == null || refresh) {
      _cache = await client.listProjects();
    }
    return _cache!;
  }

  Future<ResolvedTarget> resolve({
    final String? project,
    final String? flavor,
  }) async {
    final List<ProjectSummary> list = await projects();
    if (list.isEmpty) {
      throw ResolveException(
        'No projects are accessible with this token. $_tokenScopeHint',
      );
    }

    final String? selector = project ?? defaultProject;
    final ProjectSummary chosen = _pickProject(list, selector);
    final String? resolvedFlavor = _pickFlavor(chosen, flavor ?? defaultFlavor);

    return ResolvedTarget(
      projectId: chosen.id,
      projectName: chosen.name,
      flavor: resolvedFlavor,
    );
  }

  ProjectSummary _pickProject(
    final List<ProjectSummary> list,
    final String? selector,
  ) {
    if (selector == null) {
      if (list.length == 1) return list.first;
      throw ResolveException(
        'Multiple projects available (${_names(list)}); say which one.',
      );
    }
    final int? asId = int.tryParse(selector);
    for (final ProjectSummary p in list) {
      if ((asId != null && p.id == asId) ||
          p.name.toLowerCase() == selector.toLowerCase()) {
        return p;
      }
    }
    // A token is scoped to one workspace, so the usual cause is a token from
    // the wrong one. Say which workspace was searched, or the list of names
    // reads like the project was deleted.
    final List<String> workspaces = <String>{
      for (final ProjectSummary p in list)
        if (p.workspace.isNotEmpty) p.workspace,
    }.toList();
    final String where = workspaces.isEmpty
        ? ''
        : ' in workspace${workspaces.length > 1 ? 's' : ''} '
            '${workspaces.map((final String w) => '"$w"').join(', ')}';
    throw ResolveException(
      'Project "$selector" not found$where. Available: ${_names(list)}. '
      '$_tokenScopeHint',
    );
  }

  String? _pickFlavor(final ProjectSummary project, final String? flavor) {
    if (flavor != null) {
      final bool exists = project.flavors.any((final FlavorSummary f) => f.name == flavor);
      if (!exists && project.flavors.isNotEmpty) {
        throw ResolveException(
          'Flavor "$flavor" not found in "${project.name}". '
          'Available: ${project.flavors.map((final FlavorSummary f) => f.name).join(", ")}.',
        );
      }
      return flavor;
    }
    if (project.flavors.length == 1) return project.flavors.first.name;
    if (project.flavors.isEmpty) return null;
    throw ResolveException(
      'Project "${project.name}" has multiple flavors '
      '(${project.flavors.map((final FlavorSummary f) => f.name).join(", ")}); specify one.',
    );
  }

  static const String _tokenScopeHint =
      'A token only reaches the workspace it was created in: for a project in '
      'another workspace, use a token from that workspace '
      '(`fl login --token ...`, or FL_API_TOKEN for one command).';

  String _names(final List<ProjectSummary> list) =>
      list.map((final ProjectSummary p) => p.name).join(', ');
}
