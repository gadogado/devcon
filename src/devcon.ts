#!/usr/bin/env node

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { spawnSync } from 'child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const BLUE = '\x1b[34m';
const GREEN = '\x1b[32m';
const CYAN = '\x1b[36m';
const YELLOW = '\x1b[33m';
const RESET = '\x1b[0m';

// Available subcommands
const SUBCOMMANDS = ['init', 'up', 'worktree', 'status', 'down', 'remove'] as const;
type Subcommand = typeof SUBCOMMANDS[number];

interface GlobalFlags {
  verbose: boolean;
  config?: string;
}

function header(text: string): void {
  console.log(`${BLUE}${'━'.repeat(60)}${RESET}`);
  console.log(`${BLUE}${text}${RESET}`);
  console.log(`${BLUE}${'━'.repeat(60)}${RESET}`);
}

function getVersion(): string {
  const pkgPath = join(__dirname, '..', 'package.json');
  const pkg = JSON.parse(readFileSync(pkgPath, 'utf-8'));
  return pkg.version;
}

function showHelp(): void {
  const version = getVersion();

  console.log('');
  header(`  devcon v${version}`);
  console.log('');
  console.log('  Ergonomic scripts for managing git worktrees with devcontainers');
  console.log('');

  console.log(`${CYAN}Usage:${RESET}`);
  console.log('');
  console.log(`  ${GREEN}devcon${RESET} [GLOBAL_FLAGS] <COMMAND> [OPTIONS]`);
  console.log('');

  console.log(`${CYAN}Global Flags:${RESET}`);
  console.log('');
  console.log(`  ${GREEN}--verbose, -v${RESET}     Enable verbose output`);
  console.log(`  ${GREEN}--config PATH${RESET}     Use custom config file`);
  console.log(`  ${GREEN}--version${RESET}         Show version number`);
  console.log(`  ${GREEN}--help, -h${RESET}        Show this help message`);
  console.log('');

  console.log(`${CYAN}Available Commands:${RESET}`);
  console.log('');
  console.log(`  ${GREEN}init${RESET}              Initialize new project with devcontainer setup`);
  console.log(`  ${GREEN}up${RESET}                Start/create devcontainer in current directory`);
  console.log(`  ${GREEN}worktree${RESET}          Create worktree + start devcontainer`);
  console.log(`  ${GREEN}status${RESET}            View all active worktrees and containers`);
  console.log(`  ${GREEN}down${RESET}              Stop devcontainer(s) for the current directory`);
  console.log(`  ${GREEN}remove${RESET}            Stop and delete devcontainer(s) for the current directory`);
  console.log('');

  console.log(`${CYAN}Examples:${RESET}`);
  console.log('');
  console.log('  # Initialize a new project');
  console.log(`  ${GREEN}devcon init${RESET}`);
  console.log('');
  console.log('  # Start devcontainer');
  console.log(`  ${GREEN}devcon up${RESET}`);
  console.log('');
  console.log('  # Create worktree with container');
  console.log(`  ${GREEN}devcon worktree${RESET} --branch feature/my-feature`);
  console.log('');
  console.log('  # View status with verbose output');
  console.log(`  ${GREEN}devcon --verbose status${RESET}`);
  console.log('');
  console.log('  # Use custom config');
  console.log(`  ${GREEN}devcon --config ~/my-config.yaml up${RESET}`);
  console.log('');
  console.log('  # Stop/remove containers for this directory');
  console.log(`  ${GREEN}devcon down${RESET}  |  ${GREEN}devcon remove${RESET}`);
  console.log('');

  console.log(`${CYAN}Command Help:${RESET}`);
  console.log('');
  console.log('  Run any command with --help for detailed usage:');
  console.log(`  ${GREEN}devcon init --help${RESET}`);
  console.log(`  ${GREEN}devcon up --help${RESET}`);
  console.log(`  ${GREEN}devcon worktree --help${RESET}`);
  console.log('');

  console.log(`${CYAN}Documentation:${RESET}`);
  console.log('');
  console.log('  https://github.com/gadogado/devcon#readme');
  console.log('');
}

function parseArgs(args: string[]): { globalFlags: GlobalFlags; subcommand?: Subcommand; subcommandArgs: string[] } {
  const globalFlags: GlobalFlags = {
    verbose: false,
  };

  let subcommand: Subcommand | undefined;
  const subcommandArgs: string[] = [];
  let foundSubcommand = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    // If we've found the subcommand, all remaining args go to it
    if (foundSubcommand) {
      subcommandArgs.push(arg);
      continue;
    }

    // Parse global flags
    if (arg === '--verbose' || arg === '-v') {
      globalFlags.verbose = true;
    } else if (arg === '--config') {
      globalFlags.config = args[++i];
    } else if (SUBCOMMANDS.includes(arg as Subcommand)) {
      subcommand = arg as Subcommand;
      foundSubcommand = true;
    } else {
      // Unknown flag before subcommand
      console.error(`${YELLOW}Unknown flag: ${arg}${RESET}`);
      console.log(`Run ${CYAN}devcon --help${RESET} for usage information.`);
      process.exit(1);
    }
  }

  return { globalFlags, subcommand, subcommandArgs };
}

function executeSubcommand(subcommand: Subcommand, globalFlags: GlobalFlags, subcommandArgs: string[]): void {
  // Build path to script
  const scriptPath = join(__dirname, '..', 'scripts', `${subcommand}.sh`);

  // Build args for the script
  const scriptArgs: string[] = [];

  // Add global flags that scripts understand
  if (globalFlags.config) {
    scriptArgs.push('--config', globalFlags.config);
  }

  // Add subcommand args
  scriptArgs.push(...subcommandArgs);

  // Set environment variables for verbose mode
  const env = { ...process.env };
  if (globalFlags.verbose) {
    env.DEVCON_VERBOSE = '1';
  }

  // Execute the script
  const result = spawnSync('bash', [scriptPath, ...scriptArgs], {
    stdio: 'inherit',
    env,
  });

  // Exit with the script's exit code
  process.exit(result.status ?? 1);
}

function main(): void {
  const args = process.argv.slice(2);

  // If version flag anywhere
  if (args.includes('--version')) {
    console.log(`devcon v${getVersion()}`);
    return;
  }

  // If no args, show help
  if (args.length === 0) {
    showHelp();
    return;
  }

  // Check if --help/-h comes before any subcommand
  const firstArg = args[0];
  if (firstArg === '--help' || firstArg === '-h') {
    showHelp();
    return;
  }

  // Parse arguments
  const { globalFlags, subcommand, subcommandArgs } = parseArgs(args);

  // If no subcommand provided
  if (!subcommand) {
    console.error(`${YELLOW}No command specified.${RESET}`);
    console.log(`Run ${CYAN}devcon --help${RESET} for usage information.`);
    process.exit(1);
  }

  // Execute the subcommand
  executeSubcommand(subcommand, globalFlags, subcommandArgs);
}

main();
