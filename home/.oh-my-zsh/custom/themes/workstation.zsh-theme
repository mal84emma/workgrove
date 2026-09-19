NEWLINE=$'\n'

OTHER_PROMPT_WIDTH=50
function PromptWidth() {
  echo $(( ${COLUMNS} - ${OTHER_PROMPT_WIDTH} ))
}

dir_width='$(PromptWidth)'
# conda_info='$(conda_prompt_info)'
git_info='$(git_prompt_info)'
# these need to be single quote references to functions so they can be re-evalated on each resize

# prompt is double quote string so that variables are evaluated/interploted
PROMPT="%{$fg_bold[green]%}%n@%m" # username & machine
PROMPT+=" %{$FG[062]%}%D{[%X]}" # current time
PROMPT+="%{$reset_color%}"
PROMPT+=" %{$fg[white]%}[%${dir_width}<...<%4~%<<]" # current dir (top 4 levels or truncated to width)
PROMPT+="%{$reset_color%}"
# PROMPT+=" ${conda_info}" # conda env info
PROMPT+=" ${git_info}" # git info
PROMPT+="$NEWLINE%{$fg_bold[blue]%}%#%{$reset_color%} " # prompt char - could add %{$fg[blue]%}->

ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg[green]%}["
ZSH_THEME_GIT_PROMPT_SUFFIX="]%{$reset_color%}"
ZSH_THEME_GIT_PROMPT_DIRTY=" %{$fg[red]%}*%{$fg[green]%}"
ZSH_THEME_GIT_PROMPT_CLEAN=""

# ZSH_THEME_CONDA_PREFIX="%{$FG[006]%}("
# ZSH_THEME_CONDA_SUFFIX=")%{$reset_color%}"