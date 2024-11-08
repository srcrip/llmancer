# LLMancer.nvim

A Neovim plugin for chatting with LLMs (currently supporting Anthropic's Claude).

## Installation

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):


todo:
- add some context on which files the user has open

You can expand this further by:
1. Adding better error handling
2. Implementing a proper chat history system
3. Adding syntax highlighting for the chat buffer
4. Adding more LLM providers
5. Adding commands instead of just Lua functions
6. Adding status indicators while waiting for responses

## Development

### Running Tests

Tests require [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) to be installed. You can install it with your package manager or run:

```bash
make deps  # This will install plenary.nvim and other development dependencies
make test  # Run the tests
```
