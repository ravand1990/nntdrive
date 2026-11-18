/// Refresh-owned path hints, not cached filesystem acceptance. Null evidence at
/// the call site retains live browser discovery; an empty index never falls back.
class PreparedConflictPaths {
  const PreparedConflictPaths(this.exact, this.candidatesByOriginal);

  final Set<String> exact;
  final Map<String, List<String>> candidatesByOriginal;
}
