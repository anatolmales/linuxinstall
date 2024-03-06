#!/usr/bin
rm -rf $HOME/.config/nvim
rm -rf $HOME/.oh-my-zsh
rm -rf ~/.zshrc.conf
rm -rf ~/.tmux.conf

#sudo dpkg-reconfigure locales
sudo apt install tmux zsh mc sudo python3-neovim -y
#install omz
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git
echo "source ${(q-)PWD}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> ${ZDOTDIR:-$HOME}/.zshrc
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
wget -O ~/.zshrc.conf https://raw.githubusercontent.com/anatolmales/linuxinstall/main/zshrc

#install nvim
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim.appimage
sudo mkdir -p /opt/nvim
sudo mv nvim.appimage /opt/nvim/nvim
chmod u+x /opt/nvim/nvim

echo 'export PATH="$PATH:/opt/nvim/"' >> ~/.bashrc
wget -O ~/.tmux.conf https://raw.githubusercontent.com/anatolmales/linuxinstall/main/tmux.conf

#install config nvim
git clone https://github.com/anatolmales/kickstart.nvim.git "${XDG_CONFIG_HOME:-$HOME/.config}"/nvim

