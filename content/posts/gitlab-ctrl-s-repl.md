---
title: "Ctrl-S is my REPL: GitLab"
date: 2024-08-12T11:46:36+02:00
draft: true
---

## Introduction

Sometimes I need to fiddle with `.gitlab-ci.yml`. What variables are set?
Will this runner image have the available tools I need?
Did I forget a `;` inside some multiline bash string of sorts?

Who doesn't enjoy occasionally writing bash scripts in YAML?

This would warrant a fast feedback loop. Until recently my "loop" has been like this:

* Ctrl-S (or Cmd-S as I'm on OS X).
* Alt-0 (git changes)
* Space (mark file to commit)
* Alt-P