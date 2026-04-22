#!/bin/bash

BASHRC="$HOME/.bashrc"

# Массив строк для добавления
LINES=(
'alias tm='tmux attach || tmux new'
'export HISTTIMEFORMAT="%h %d %H:%M:%S "'
'export HISTFILESIZE=5000'
'shopt -s histappend'
'PROMPT_COMMAND="history -a"'
)

echo ">>> Настройка ~/.bashrc ..."

# Проверка и добавление строк, если их нет
for LINE in "${LINES[@]}"; do
    if ! grep -qxF "$LINE" "$BASHRC"; then
        echo "$LINE" >> "$BASHRC"
        echo "Добавлено: $LINE"
    else
        echo "Пропущено (уже есть): $LINE"
    fi
done

# Применение изменений
if [[ "$0" == "bash" || "$0" == "-bash" ]]; then
    # Если скрипт запущен через source
    source "$BASHRC"
else
    # Если скрипт запущен напрямую
    exec bash
fi

echo ">>> Настройка завершена!"
