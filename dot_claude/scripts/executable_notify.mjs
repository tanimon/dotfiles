#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, openSync, readSync, statSync, closeSync } from "node:fs";
import path from "node:path";
import os from "node:os";

try {
  const input = JSON.parse(readFileSync(process.stdin.fd, "utf8"));
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
    process.exit(0);
  }

  if (!existsSync(resolvedPath)) {
    console.log("Hook execution failed: Transcript file does not exist");
    process.exit(0);
  }

  // Read only the last chunk of the file to avoid OOM on large transcripts
  const TAIL_BYTES = 8192;
  const fileStat = statSync(resolvedPath);
  if (fileStat.size === 0) {
    console.log("Hook execution failed: Transcript file is empty");
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
    console.log("Hook execution failed: Transcript file is empty");
    process.exit(0);
  }

  const lastLine = lines[lines.length - 1];
  const transcript = JSON.parse(lastLine);
  const lastMessageContent = transcript?.message?.content?.[0]?.text;

  if (lastMessageContent) {
    const script = `
          on run {notificationTitle, notificationMessage}
            try
              display notification notificationMessage with title notificationTitle sound name "Glass"
            end try
          end run
        `;
    execFileSync(
      "osascript",
      ["-e", script, "Claude Code", lastMessageContent],
      {
        stdio: "ignore",
      }
    );
  }
} catch (error) {
  console.error("Hook execution failed:", error.message);
  process.exit(1);
}
