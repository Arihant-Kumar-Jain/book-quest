# 🧩 Example: C++ Crash Course

The hand-tuned setup Book Quest grew out of, for *C++ Crash Course* by Josh Lospinoso (No Starch Press, 2019).
It shows everything a `book.json` can do beyond what `./quest add` generates:

- **98 exercises**, compile-checked with `clang++ -std=c++20 -Wall -Wextra` (`"code": "cpp"`), with a bonus for
  warning-free builds. Ids match the book (2-1, 2-2 …); exercise descriptions are short paraphrases.
- **8 project bosses** (a RAII container, an RPN calculator, a key-value store with `tests/*.in` → `.out`
  checks, a thread pool, a Boost.Asio chat server…) built with AddressSanitizer + UBSan or ThreadSanitizer.
- **4 side books** (*The Art of Debugging*, *The GNU Make Book*, *The Pragmatic Programmer*, *PGP & GPG*) with
  hand-picked reading quests and hands-on labs tied to the C++ work.
- **Custom level titles** ("Pointer Wrangler", "RAII Apprentice" …) and named parts.
- **A Linux toolbox:** `.devcontainer/` (GCC, GDB, Valgrind, strace, Make 4.3, CMake, Boost), plus `.vscode/`
  build and debug tasks and a `.clangd` file.

## Use it

You need your own copy of the book (and of any side books you want).

```bash
cp examples/cpp-crash-course/book.json .quest/book.json
cp -R examples/cpp-crash-course/.devcontainer examples/cpp-crash-course/.vscode examples/cpp-crash-course/.clangd .
# put the book's PDF in the top folder: any filename containing "Crash Course" works
./quest init
./quest
```

Side-book PDFs go anywhere in the folder; each side book finds its PDF by a word from its filename
(`pdf_match` in `book.json`). Boost is needed for chapters 12–13, 15–16, 20–21 and Boss 8: it's in the dev
container, or `brew install boost` on a Mac.
