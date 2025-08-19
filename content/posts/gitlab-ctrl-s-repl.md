---
title: "Ctrl-S is my REPL: GitLab"
date: 2025-08-19T11:46:36+02:00
draft: true
---

## Introduction

Sometimes I need to fiddle with `.gitlab-ci.yml`. What variables are set?
Will this runner image have the available tools I need?
Did I forget a `;` inside some multiline string?
Ah, writing bash inside YAML: who doesn't enjoy it?

A fast feedback loop is always good. Until recently my feedback loop has been like this:

* Make an actual change.
* Ctrl-S: save the file.
* Alt-0: go to git changes.
* Space: mark file to commit.
* Alt-P: push marked changes.
* Alt-P again: yes, push those changes.
* Ctrl-F: focus Firefox.
* Ctrl-R: refresh git lab pipeline.
* Click the pipeline.
* Click the job.
* Wait for the output to appear, maybe scroll down.
* Whoops, the line should start with `- |` not `- >`.
* Ctrl-X: go to IDE, then go to start.

Phew. That's a lot of keystrokes for viewing the effect of, say, a single comma.
Add the wonderful experience of writing bash in YAML.
No wonder my head is spinning after a long day of work.

## Ctrl-S as a REPL

REPL is an abbrevation for `read, eval, print, loop`.
It's particularly well known in the Lisp family of languages.
The concept, instant feedback, is helpful in all
languages though.

How about having `Ctrl-S` doing all of the manual steps above?
There is already the GitLab CLI tool,
[glab](https://docs.gitlab.com/editor_extensions/gitlab_cli/), that can
do most of the work.

I wrote [taillog](https://raw.githubusercontent.com/ivarref/nix/0c85edfd0d006c23ba0b6c5fbc5e13d39d365588/bin/taillog.sh)
towards this effort.
It will:

* Push changed, i.e. modified files, automatically.
* Dump the contents of the latest job.

