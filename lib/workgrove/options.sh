# shellcheck shell=bash
# WT_COMMANDS fields: name, comma-separated aliases, remote mode, summary, options, remote option override.
# Remote modes are local, forward, forward with -r, or a host_* function.
# Option specs start with a positional key or a ! policy that preserves existing error messages.
# Semicolons separate options. Colons separate aliases, output key, value noun, and optional validator.
# A flag uses =VALUE instead of a value noun. An @error key rejects a spelling with a diagnostic hint.
# Remote overrides beginning with +; append rules to the direct specification.
WT_COMMANDS='new||host_new|Create a task.|name;-p,--prompt:prompt:a brief;--prompt-stdin:stdin_prompt:=1;-b,--base:base:a ref;--head:from_head:=1;-a,--agent:agent:an agent;-m,--model:model:a model:need_model;--no-workspace:workspace:=0;-r,--repo:repo:a repo|+;-m?*:@error:use -m <model>
attach||host_attach|Open or recover a task row.|name;-a,--agent:agent:an agent;-p,--prompt:prompt:a brief;-r,--repo:repo:a repo|name;--restart-agent:restart:=1;--reattach:reattach:=1;-r,--repo:repo:a repo
list|ls|host_list|List tasks.|!unknown;--all:all:=1;--json:format:=json;-r,--repo:repo:a repo|
show||forward with -r|Show task status.|name;--diff:diff:=1;--json:format:=json;-r,--repo:repo:a repo|
rm|remove|host_rm|Remove a task.|name;--force,-f:force:=1;--keep-branch:keep:=1;--discard-commits:discard_commits:=1;-r,--repo:repo:a repo|
path||forward with -r|Print a task path.|name;-r,--repo:repo:a repo|
open||host_open|Open a task in VS Code.|name;-r,--repo:repo:a repo|
repos||host_repos|List or locate repositories.|name!repos;--porcelain:mode:=porcelain;--table:mode:=table|
version||forward|Show commit and protocol.|!none|
update||host_update|Update workgrove.|!unknown;--refresh-config,--opinionated-config,--with-*:pass_flag:=1|
setup||host_setup|Install or restore a portable remote profile.|!unknown;--root:root:an absolute path;--storage:storage:volume or os-disk;--mount:mount:a mount path;--trust-personal-volume:trust:=1;--strict-permissions:strict:=1;--source:source:a public HTTPS URL;--revision:revision:a full commit;--git-identity:git_identity:a remote identity file;--persist-agents:persist:=1;--with-tmux-conf:tmux:=1;--restore-only:restore:=1;--claude-args-json:claude_args:a JSON array;--codex-args-json:codex_args:a JSON array|
doctor||host_doctor|Inspect remote readiness without repair.|!unknown;--root:root:an absolute path;--json:json:=1|
help|-h,--help|forward|Show usage.|!unknown|
run||local|Run the task agent.|name;-r,--repo:repo:a repo|
diff||local|Show task status and open its diff.|name;--diff:diff:=1;-r,--repo:repo:a repo|
sync||local|Sync a task with its base.|name;--merge:merge:=1;-r,--repo:repo:a repo|
pr||local|Push and open a pull request.|name;--draft:draft_flag:=1;-r,--repo:repo:a repo|
prune||local|Remove merged tasks.|!unknown;--dry-run,-n:dry:=1;-r,--repo:repo:a repo|
hosts||local|Probe SSH hosts.|!hosts;--json:format:=json|
task||local|Open the task picker.|!unknown;--where:where:local or a host;-a,--agent:kind:a kind;-r,--repo:repo:a repo;-p,--prompt:brief:a brief|
driver||local|Open the driver row.|!none|
current|cur|local|Show the current checkout.|!none|'

wt_command() {
  local name aliases mode summary spec remote
  while IFS='|' read -r name aliases mode summary spec remote; do
    # The dispatcher in bin/wt reads WT_REMOTE.
    # shellcheck disable=SC2034
    case ",$name,$aliases," in
      *",$1,"*) WT_COMMAND=$name WT_REMOTE=$mode WT_SUMMARY=$summary WT_SPEC=$spec WT_REMOTE_SPEC=${remote:-$spec}; return 0 ;;
    esac
  done <<<"$WT_COMMANDS"
  return 1
}

wt_spec() {
  wt_command "$1" || return
  local spec=$WT_SPEC
  if [[ ${2:-} == remote ]]; then
    if [[ $WT_REMOTE_SPEC == '+;'* ]]; then spec+=${WT_REMOTE_SPEC:1}
    else spec=$WT_REMOTE_SPEC; fi
  fi
  printf '%s|%s\n' "$WT_COMMAND" "${spec//;/$'\n'}" | tr ':' '|'
}

wt_remote_commands() {
  local name aliases mode rest out=''
  while IFS='|' read -r name aliases mode rest; do
    [[ $mode != local ]] || continue
    out+=${out:+$1}$name
  done <<<"$WT_COMMANDS"
  printf '%s' "$out"
}

wt_usage() {
  local remote
  remote="wt -H <host> <$(wt_remote_commands '|')> …"
  awk -v remote="$remote" 'NR>1 && /^#/ {gsub(/@WT_REMOTE_USAGE@/, remote); print; next} NR>1 {exit}' "$0"
}

wt_command_help() {
  local command=$1 text
  wt_command "$command" || return
  text=$(wt_usage | awk -v command="$WT_COMMAND" '
    /^#   wt / {selected=($3 == command)}
    selected {print}')
  if [[ -n $text ]]; then printf '%s\n' "$text"; else printf '#   wt %s    %s\n' "$WT_COMMAND" "$WT_SUMMARY"; fi
  if [[ $WT_COMMAND == attach ]]; then
    printf '%s\n' '#   wt -H <host> attach <name> -r REPO [--reattach|--restart-agent]' \
      '#     With -H, attach rejects -a/--agent and -p/--prompt.' \
      '#     Direct attach rejects --reattach and --restart-agent.' \
      '#     Direct attach can run on the Mac or inside a VM.'
  fi
}

# wt_opts <spec> <associative output> <args...>. Repeated options keep their last value.
# The first spec line gives the command and positional policy. Other lines describe options.
# Keys beginning with @ retain argument order and spelling for forwarding through wt_opt_args.
# Output variable names must not begin with __.
wt_opts() {
  local __spec=$1
  local -n __out=$2
  shift 2
  local __command __position __row __aliases __key __kind __check __alias __option __value __found
  local __end=0 __equal __count=0 __original __unknown __unexpected
  local -a __rows=() __names=()
  mapfile -t __rows <<<"$__spec"
  IFS='|' read -r __command __position <<<"${__rows[0]}"
  __out=()
  while (($#)); do
    __original=$1 __option=$1 __equal=0 __value='' __found=0
    if [[ $__end == 0 && $1 == -- ]]; then
      __end=1; __out[@delimiter]=1; shift; continue
    fi
    if [[ $__end == 0 && $1 == --*=* ]]; then
      __option=${1%%=*} __value=${1#*=} __equal=1
    fi
    if [[ $__end == 0 && $__equal == 0 && ( $__option == -h || $__option == --help ) ]]; then
      wt_command_help "${WT_HELP_COMMAND:-$__command}"
      exit 0
    fi
    if [[ $__end == 0 ]]; then
      for __row in "${__rows[@]:1}"; do
        IFS='|' read -r __aliases __key __kind __check <<<"$__row"
        IFS=',' read -r -a __names <<<"$__aliases"
        for __alias in "${__names[@]}"; do
          # The update command deliberately accepts the installer's --with-* family.
          # shellcheck disable=SC2254
          case "$__option" in $__alias) __found=1; break ;; esac
        done
        [[ $__found == 1 ]] && break
      done
    fi
    if [[ $__found == 1 ]]; then
      [[ $__key != @error ]] || die "$__command: unknown option $__original ($__kind)"
      if [[ $__kind == =* ]]; then
        [[ $__equal == 0 ]] || die "$__command: unknown option $__original"
        __value=${__kind#=}
      else
        if [[ $__equal == 0 ]]; then
          [[ $# -ge 2 ]] || die "$__command: $__option needs $__kind"
          __value=$2; shift
        fi
        [[ -z $__check ]] || "$__check" "$__value"
      fi
      # The output nameref names an associative array.
      # shellcheck disable=SC2004
      __out[$__key]=$__value
      __out[@option:$__count]=$__option
      __out[@kind:$__count]=$__kind
    else
      __unknown="$__command: unknown option $__original"
      __unexpected="$__command: unexpected argument $__original"
      case "$__position" in
        '!hosts') die 'hosts: usage: wt hosts [--json]' ;;
        '!none') die "$__unexpected (wt $__command takes none)" ;;
        '!unknown') die "$__unknown" ;;
        'name!repos')
          [[ $__end == 1 || $__original != -* ]] || die "$__unknown (wt repos [<name>] [--porcelain|--table])"
          [[ -z ${__out[name]:-} ]] || die 'repos: one name at most (wt repos [<name>])' ;;
        *)
          [[ $__end == 1 || $__original != -* ]] || die "$__unknown"
          [[ -z ${__out[$__position]:-} ]] || die "$__unexpected" ;;
      esac
      __key=${__position%%!*} __value=$__original
      # The output nameref names an associative array.
      # shellcheck disable=SC2004
      __out[$__key]=$__value
      __out[@option:$__count]=''
      __out[@kind:$__count]=''
    fi
    __out[@key:$__count]=$__key
    __out[@value:$__count]=$__value
    __count=$((__count + 1))
    shift
  done
  __out[@count]=$__count
}

# Rebuild arguments without losing values, repeated options, or positional option boundaries.
wt_opt_args() {
  local -n __opts=$1 __args=$2
  shift 2
  local __i __key __option __kind __skip __exclude
  local -a __positions=()
  __args=()
  for ((__i=0; __i<${__opts[@count]}; __i++)); do
    __key=${__opts[@key:$__i]} __option=${__opts[@option:$__i]} __kind=${__opts[@kind:$__i]} __skip=0
    for __exclude in "$@"; do [[ $__key != "$__exclude" ]] || __skip=1; done
    [[ $__skip == 0 ]] || continue
    if [[ -z $__option ]]; then __positions+=("${__opts[@value:$__i]}")
    else
      __args+=("$__option")
      [[ $__kind == =* ]] || __args+=("${__opts[@value:$__i]}")
    fi
  done
  [[ ! -v __opts[@delimiter] ]] || __args+=(--)
  __args+=("${__positions[@]}")
}
