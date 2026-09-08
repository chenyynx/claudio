import '../../../services/prompt_history_service.dart';

class PromptHistoryState {
  final List<PromptHistoryEntry> prompts;
  final PromptSortOrder sortOrder;
  final bool isLoading;
  final bool hasMore;
  final PromptHistoryFilters filters;
  final bool filtersExpanded;

  const PromptHistoryState({
    this.prompts = const [],
    this.sortOrder = PromptSortOrder.frequency,
    this.isLoading = false,
    this.hasMore = true,
    this.filters = const PromptHistoryFilters(),
    this.filtersExpanded = false,
  });

  PromptHistoryState copyWith({
    List<PromptHistoryEntry>? prompts,
    PromptSortOrder? sortOrder,
    bool? isLoading,
    bool? hasMore,
    PromptHistoryFilters? filters,
    bool? filtersExpanded,
  }) {
    return PromptHistoryState(
      prompts: prompts ?? this.prompts,
      sortOrder: sortOrder ?? this.sortOrder,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      filters: filters ?? this.filters,
      filtersExpanded: filtersExpanded ?? this.filtersExpanded,
    );
  }
}
