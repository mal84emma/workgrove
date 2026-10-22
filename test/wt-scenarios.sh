# shellcheck shell=bash
# Keep scenario IDs and names in one registry for discovery and execution.
wt_scenarios() {
  "$@" scenario_guard "0. guard_scratch_root refuses anything outside this run's scratch root"
  "$@" scenario_new_and_sidecar "1. wt new: the worktree, the branch, the sidecar and the brief"
  "$@" scenario_task_model "1b. a task model persists and wins on every agent launch"
  "$@" scenario_base_resolution "2. wt new: the base is canonicalised, so rm and prune can trust it"
  "$@" scenario_names_and_collisions "3. wt new: tidied names, generated names, refused names, taken names"
  "$@" scenario_list_show_path "4. wt list / show / path / open"
  "$@" scenario_show_limits "4b. wt show keeps every section for long task reports"
  "$@" scenario_include_and_setup "5. .wt-include copies ignored files; .wt-setup runs in the new worktree"
  "$@" scenario_rm_refusals "6. wt rm refuses to destroy work, and --force is the one way past it"
  "$@" scenario_squash_merge "6b. wt rm after a squash merge: work that landed is not a reason, work that did not still is"
  "$@" scenario_prune_agrees "7. wt prune --dry-run keeps exactly what wt rm refuses"
  "$@" scenario_self_rm_vm "7b. a VM task can remove itself after changing to its main checkout"
  "$@" scenario_cmux "8. a cmux that is not running, and one that is"
  "$@" scenario_host_args "9. wt -H: the checks that happen before any ssh"
  "$@" scenario_connected_attach "10. wt -H attach checks connected clients and shell prompts"
  "$@" scenario_shared_helpers "11. bash startup, shared library loading, and tmux launch behavior"
  "$@" scenario_cleanup_guard "12. lib_cleanup refuses a scratch root it must not remove"
}
