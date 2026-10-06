NEWLINE=$'\n'

OTHER_PROMPT_WIDTH=50
function PromptWidth() {
  echo $(( ${COLUMNS} - ${OTHER_PROMPT_WIDTH} ))
}

dir_width='$(PromptWidth)'
git_info='$(git_prompt_info)'
# dir_width and git_info must be single-quoted references to functions, so that zsh evaluates
# them again on each resize.

# PROMPT is a double-quoted string, so that zsh interpolates the variables in it.
PROMPT="%{$fg_bold[green]%}%n@%m" # user name and machine
PROMPT+=" %{$FG[062]%}%D{[%X]}" # current time
PROMPT+="%{$reset_color%}"
PROMPT+=" %{$fg[white]%}[%${dir_width}<...<%4~%<<]" # current dir (top 4 levels or truncated to width)
PROMPT+="%{$reset_color%}"
PROMPT+=" ${git_info}" # git info
PROMPT+="$NEWLINE%{$fg_bold[blue]%}%#%{$reset_color%} " # prompt char; could add %{$fg[blue]%}->

ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg[green]%}["
ZSH_THEME_GIT_PROMPT_SUFFIX="]%{$reset_color%}"
ZSH_THEME_GIT_PROMPT_DIRTY=" %{$fg[red]%}*%{$fg[green]%}"
ZSH_THEME_GIT_PROMPT_CLEAN=""

