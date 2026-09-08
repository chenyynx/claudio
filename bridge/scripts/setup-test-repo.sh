#!/bin/bash
# =============================================================================
# Git Operations 検証用リポジトリのセットアップ
#
# Usage:
#   bash scripts/setup-test-repo.sh          # 作成 (~/Workspace/git-ops-sandbox)
#   bash scripts/setup-test-repo.sh --reset   # リセット (差分を初期状態に戻す)
#   bash scripts/setup-test-repo.sh --clean   # 完全削除
# =============================================================================

set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/Workspace/git-ops-sandbox}"
BRANCH="feat/add-todo-features"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[setup]${NC} $1"; }
warn()  { echo -e "${YELLOW}[setup]${NC} $1"; }
error() { echo -e "${RED}[setup]${NC} $1"; }

# --- Clean ---
if [[ "${1:-}" == "--clean" ]]; then
  if [[ -d "$REPO_DIR" ]]; then
    rm -rf "$REPO_DIR"
    info "Deleted $REPO_DIR"
  else
    warn "Nothing to clean: $REPO_DIR does not exist"
  fi
  exit 0
fi

# --- Reset ---
if [[ "${1:-}" == "--reset" ]]; then
  if [[ ! -d "$REPO_DIR" ]]; then
    error "$REPO_DIR does not exist. Run without --reset first."
    exit 1
  fi
  cd "$REPO_DIR"
  git checkout "$BRANCH" 2>/dev/null || true
  git reset --hard
  git clean -fd
  info "Reset to clean state. Re-applying changes..."
  # Fall through to apply changes
fi

# --- Create repo ---
if [[ ! -d "$REPO_DIR" ]]; then
  info "Creating test repo at $REPO_DIR"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
  git init
  git config user.email "test@example.com"
  git config user.name "Test User"

  # ===== Initial commit: Simple TODO app =====

  mkdir -p lib test

  cat > lib/todo.dart << 'DART'
class Todo {
  final String id;
  final String title;
  bool completed;

  Todo({required this.id, required this.title, this.completed = false});

  void toggle() {
    completed = !completed;
  }

  @override
  String toString() => '[${ completed ? "x" : " " }] $title';
}
DART

  cat > lib/todo_list.dart << 'DART'
import 'todo.dart';

class TodoList {
  final List<Todo> _items = [];

  List<Todo> get items => List.unmodifiable(_items);

  void add(String title) {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    _items.add(Todo(id: id, title: title));
  }

  void remove(String id) {
    _items.removeWhere((t) => t.id == id);
  }

  void toggle(String id) {
    final todo = _items.firstWhere((t) => t.id == id);
    todo.toggle();
  }

  int get total => _items.length;
  int get completedCount => _items.where((t) => t.completed).length;
  int get pendingCount => total - completedCount;
}
DART

  cat > lib/main.dart << 'DART'
import 'todo_list.dart';

void main() {
  final list = TodoList();

  list.add('Buy groceries');
  list.add('Write tests');
  list.add('Deploy app');

  list.toggle(list.items.first.id);

  print('=== TODO App ===');
  for (final todo in list.items) {
    print(todo);
  }
  print('${list.completedCount}/${list.total} completed');
}
DART

  cat > test/todo_test.dart << 'DART'
import '../lib/todo.dart';
import '../lib/todo_list.dart';

void main() {
  // Test Todo
  final todo = Todo(id: '1', title: 'Test task');
  assert(todo.completed == false);
  todo.toggle();
  assert(todo.completed == true);
  assert(todo.toString() == '[x] Test task');

  // Test TodoList
  final list = TodoList();
  list.add('Task A');
  list.add('Task B');
  assert(list.total == 2);
  assert(list.pendingCount == 2);

  list.toggle(list.items.first.id);
  assert(list.completedCount == 1);

  list.remove(list.items.last.id);
  assert(list.total == 1);

  print('All tests passed!');
}
DART

  cat > README.md << 'MD'
# TODO App

A simple TODO application for testing git operations.

## Usage

```bash
dart run lib/main.dart
dart run test/todo_test.dart
```
MD

  cat > .gitignore << 'GI'
.dart_tool/
build/
*.log
GI

  git add .
  git commit -m "feat: initial TODO app with basic CRUD"

  # ===== Second commit: add priority =====

  cat > lib/todo.dart << 'DART'
enum Priority { low, medium, high }

class Todo {
  final String id;
  final String title;
  bool completed;
  Priority priority;

  Todo({
    required this.id,
    required this.title,
    this.completed = false,
    this.priority = Priority.medium,
  });

  void toggle() {
    completed = !completed;
  }

  @override
  String toString() {
    final mark = completed ? 'x' : ' ';
    final prio = priority.name[0].toUpperCase();
    return '[$mark][$prio] $title';
  }
}
DART

  git add .
  git commit -m "feat: add priority levels to todos"

  # ===== Create feature branch =====
  git checkout -b "$BRANCH"

  info "Repo created with 2 commits on main, now on $BRANCH"
else
  cd "$REPO_DIR"
  git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
  info "Using existing repo at $REPO_DIR"
fi

# ===== Apply working-tree changes (unstaged) =====

cd "$REPO_DIR"

# --- Change 1: Add due date to Todo (modify existing file, 2 hunks) ---
cat > lib/todo.dart << 'DART'
enum Priority { low, medium, high }

class Todo {
  final String id;
  final String title;
  bool completed;
  Priority priority;
  DateTime? dueDate;

  Todo({
    required this.id,
    required this.title,
    this.completed = false,
    this.priority = Priority.medium,
    this.dueDate,
  });

  void toggle() {
    completed = !completed;
  }

  bool get isOverdue =>
      dueDate != null && !completed && dueDate!.isBefore(DateTime.now());

  @override
  String toString() {
    final mark = completed ? 'x' : ' ';
    final prio = priority.name[0].toUpperCase();
    final due = dueDate != null ? ' (due: ${dueDate!.toIso8601String().split("T").first})' : '';
    return '[$mark][$prio] $title$due';
  }
}
DART

# --- Change 2: Add filter/sort to TodoList (modify, multiple hunks) ---
cat > lib/todo_list.dart << 'DART'
import 'todo.dart';

class TodoList {
  final List<Todo> _items = [];

  List<Todo> get items => List.unmodifiable(_items);

  void add(String title, {Priority priority = Priority.medium, DateTime? dueDate}) {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    _items.add(Todo(id: id, title: title, priority: priority, dueDate: dueDate));
  }

  void remove(String id) {
    _items.removeWhere((t) => t.id == id);
  }

  void toggle(String id) {
    final todo = _items.firstWhere((t) => t.id == id);
    todo.toggle();
  }

  /// Filter by completion status.
  List<Todo> filter({bool? completed}) {
    if (completed == null) return items;
    return _items.where((t) => t.completed == completed).toList();
  }

  /// Sort by priority (high first) then by due date.
  List<Todo> sorted() {
    final sorted = List<Todo>.from(_items);
    sorted.sort((a, b) {
      final prioCmp = b.priority.index.compareTo(a.priority.index);
      if (prioCmp != 0) return prioCmp;
      if (a.dueDate == null && b.dueDate == null) return 0;
      if (a.dueDate == null) return 1;
      if (b.dueDate == null) return -1;
      return a.dueDate!.compareTo(b.dueDate!);
    });
    return sorted;
  }

  int get total => _items.length;
  int get completedCount => _items.where((t) => t.completed).length;
  int get pendingCount => total - completedCount;
  int get overdueCount => _items.where((t) => t.isOverdue).length;
}
DART

# --- Change 3: New file (storage layer) ---
cat > lib/storage.dart << 'DART'
import 'dart:convert';
import 'dart:io';

import 'todo.dart';

/// Simple JSON file storage for todos.
class TodoStorage {
  final String filePath;

  TodoStorage(this.filePath);

  Future<List<Todo>> load() async {
    final file = File(filePath);
    if (!await file.exists()) return [];

    final content = await file.readAsString();
    final list = jsonDecode(content) as List;
    return list.map((e) {
      final map = e as Map<String, dynamic>;
      return Todo(
        id: map['id'] as String,
        title: map['title'] as String,
        completed: map['completed'] as bool? ?? false,
        priority: Priority.values.byName(map['priority'] as String? ?? 'medium'),
        dueDate: map['dueDate'] != null ? DateTime.parse(map['dueDate'] as String) : null,
      );
    }).toList();
  }

  Future<void> save(List<Todo> todos) async {
    final data = todos.map((t) => {
      'id': t.id,
      'title': t.title,
      'completed': t.completed,
      'priority': t.priority.name,
      'dueDate': t.dueDate?.toIso8601String(),
    }).toList();
    await File(filePath).writeAsString(jsonEncode(data));
  }
}
DART

# --- Change 4: Update tests ---
cat > test/todo_test.dart << 'DART'
import '../lib/todo.dart';
import '../lib/todo_list.dart';

void main() {
  // Test Todo
  final todo = Todo(id: '1', title: 'Test task');
  assert(todo.completed == false);
  todo.toggle();
  assert(todo.completed == true);
  assert(todo.toString() == '[x][M] Test task');

  // Test due date
  final overdue = Todo(
    id: '2',
    title: 'Overdue',
    dueDate: DateTime.now().subtract(Duration(days: 1)),
  );
  assert(overdue.isOverdue == true);

  final future = Todo(
    id: '3',
    title: 'Future',
    dueDate: DateTime.now().add(Duration(days: 7)),
  );
  assert(future.isOverdue == false);

  // Test TodoList
  final list = TodoList();
  list.add('Task A', priority: Priority.high);
  list.add('Task B', priority: Priority.low);
  list.add('Task C');
  assert(list.total == 3);
  assert(list.pendingCount == 3);

  list.toggle(list.items.first.id);
  assert(list.completedCount == 1);

  // Test filter
  assert(list.filter(completed: true).length == 1);
  assert(list.filter(completed: false).length == 2);

  // Test sort
  final sorted = list.sorted();
  assert(sorted.first.priority == Priority.high);

  list.remove(list.items.last.id);
  assert(list.total == 2);

  print('All tests passed!');
}
DART

# --- Change 5: Update README ---
cat > README.md << 'MD'
# TODO App

A simple TODO application for testing git operations.

## Features

- Create, read, update, delete todos
- Priority levels (low, medium, high)
- Due dates with overdue detection
- Filter by completion status
- Sort by priority and due date
- JSON file persistence

## Usage

```bash
dart run lib/main.dart
dart run test/todo_test.dart
```

## Storage

Todos are persisted to a JSON file. Set the path via `TodoStorage`:

```dart
final storage = TodoStorage('todos.json');
await storage.save(todoList.items);
```
MD

# ===== Stage some files (pre-staged for testing) =====
git add lib/storage.dart README.md

info "Done! Test repo ready at $REPO_DIR"
info ""
info "Current state:"
info "  Branch: $BRANCH"
info "  Staged:   lib/storage.dart, README.md"
info "  Unstaged:  lib/todo.dart, lib/todo_list.dart, test/todo_test.dart"
info ""
info "  5 files changed across 4 categories:"
info "    - Modified (2 hunks): lib/todo.dart"
info "    - Modified (3 hunks): lib/todo_list.dart"
info "    - New file:           lib/storage.dart  [staged]"
info "    - Modified:           test/todo_test.dart"
info "    - Modified:           README.md         [staged]"
echo ""
info "Usage:"
info "  ccpocket → connect → open session for $REPO_DIR → Diff viewer"
info "  Reset:  bash scripts/setup-test-repo.sh --reset"
info "  Delete: bash scripts/setup-test-repo.sh --clean"
