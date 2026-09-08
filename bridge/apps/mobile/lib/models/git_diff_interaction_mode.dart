enum GitDiffInteractionMode { quickActions, scrollFirst }

GitDiffInteractionMode gitDiffInteractionModeFromRaw(String? raw) {
  return switch (raw) {
    'scrollFirst' => GitDiffInteractionMode.scrollFirst,
    _ => GitDiffInteractionMode.quickActions,
  };
}
