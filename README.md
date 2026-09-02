# Omarchy Replicant — Plugin

Plugin Omarchy 4 que añade `omarchy-replicant` para sincronizar todo tu workspace vía GitHub.

Instala con:

```bash
omarchy plugin add https://github.com/tymurbogach/omarchy-replicant-plugin --enable
```

Luego:

```bash
omarchy-replicant init
omarchy-replicant create omarchy-replicant --public --push
# en otra máquina:
omarchy-replicant clone https://github.com/<user>/omarchy-replicant
omarchy-replicant restore --yes
```

El repo de tus dotfiles es `omarchy-replicant` (https://github.com/tymurbogach/omarchy-replicant) — separado de este plugin.
