#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, openSync, readSync, statSync, closeSync } from "node:fs";
import path from "node:path";
import os from "node:os";

interface HookInput {
  transcript_path?: string;
}

interface TranscriptMessage {
  content?: ReadonlyArray<{ text?: string }>;
}

interface TranscriptEntry {
  message?: TranscriptMessage;
}

try {
  const input: HookInput = JSON.parse(readFileSync(process.stdin.fd, "utf8"));
  if (!input.transcript_path) {
    process.exit(0);
  }

  const homeDir = os.homedir();
  let transcriptPath = input.transcript_path;

  if (transcriptPath.startsWith("~/")) {
    transcriptPath = path.join(homeDir, transcriptPath.slice(2));
  }

  const allowedBase = path.join(homeDir, ".claude", "projects");
  const resolvedPath = path.resolve(transcriptPath);

  if (!resolvedPath.startsWith(allowedBase)) {
    console.error("notify: transcript path outside allowed directory, skipping");
    process.exit(0);
  }

  if (!existsSync(resolvedPath)) {
    process.exit(0);
  }

  // Read only the last chunk of the file to avoid OOM on large transcripts.
  // Use a generous buffer since JSONL entries can be large (tool results, long responses).
  const TAIL_BYTES = 65536;
  const fileStat = statSync(resolvedPath);
  if (fileStat.size === 0) {
    process.exit(0);
  }
  const fd = openSync(resolvedPath, "r");
  const readSize = Math.min(TAIL_BYTES, fileStat.size);
  const buf = Buffer.alloc(readSize);
  readSync(fd, buf, 0, readSize, fileStat.size - readSize);
  closeSync(fd);

  const chunk = buf.toString("utf-8");
  const lines = chunk.split("\n").filter((line) => line.trim());
  if (lines.length === 0) {
    process.exit(0);
  }

  // When tail-reading, the first line is almost always a partial fragment.
  // Drop it unless we read from the start of the file.
  const completeLines = readSize < fileStat.size ? lines.slice(1) : lines;
  if (completeLines.length === 0) {
    process.exit(0);
  }

  // Try parsing from the last line backwards to find a valid JSONL entry.
  let transcript: TranscriptEntry | undefined;
  for (let i = completeLines.length - 1; i >= 0; i--) {
    try {
      transcript = JSON.parse(completeLines[i]) as TranscriptEntry;
      break;
    } catch {
      // Skip malformed lines
    }
  }
  if (!transcript) {
    process.exit(0);
  }
  const lastMessageContent = transcript?.message?.content?.[0]?.text;

  if (lastMessageContent) {
    const script = `
          on run {notificationTitle, notificationMessage}
            try
              display notification notificationMessage with title notificationTitle sound name "Glass"
            end try
          end run
        `;
    execFileSync("osascript", ["-e", script, "Claude Code", lastMessageContent], {
      stdio: "ignore",
    });
  }
} catch (error) {
  // Notification is best-effort — log for debugging but never block Claude Code
  console.error(`notify: ${(error as Error).message}`);
  process.exit(0);
}
