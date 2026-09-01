# universalmutator, containerised.
#
# pi1 cannot install this on the host: it has no pip and no pipx, python 3.13 is
# PEP 668 externally-managed, and `python3 -m venv` cannot bootstrap pip because
# ensurepip ships no bundled wheels here (the fix, `apt install python3-venv`,
# needs root). Containerising is also this repo's established answer for tools the
# host lacks -- alpine/git for git on the NAS, koalaman/shellcheck for shellcheck,
# the Playwright image for the e2e suite.
#
# Both versions are PINNED on purpose. Generated mutants are only comparable
# between runs if the generator is identical; a floating install silently changes
# what the survivor ledger means. This repo has already paid for a floating
# `npm install` against a pinned base image once (see CLAUDE.md, the Playwright
# browser mismatch).
#
# -slim, not -alpine: universalmutator pulls python-levenshtein, a C extension.
# glibc/manylinux wheels exist for arm64; musl would risk a source build with no
# compiler in the image.
FROM python:3.12-slim@sha256:09f7da3bc104798d0afb40bc08d23ab2da20a76130cec1f2ef170848f5d85217
RUN pip install --no-cache-dir universalmutator==1.14.1
WORKDIR /mnt
ENTRYPOINT ["mutate"]
