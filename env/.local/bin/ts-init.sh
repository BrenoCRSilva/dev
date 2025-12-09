#!/usr/bin/env bash

# Initialize bun project (creates package.json + tsconfig.json)
bun init -y

# Install dev dependencies
echo "📦 Installing dev dependencies..."
bun add -d eslint @typescript-eslint/parser @typescript-eslint/eslint-plugin \
    prettier eslint-config-prettier

# Copy config files (no tsconfig, bun handles it)
echo "⚙️  Copying config files..."
cp ~/.config/templates/typescript/eslint.config.js .
cp ~/.config/templates/typescript/.prettierrc.json .
cp ~/.config/templates/typescript/.gitignore .

# Create basic structure
mkdir -p src

echo "✅ TypeScript project initialized!"
echo ""
echo "Config files added"
