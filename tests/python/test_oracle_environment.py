"""The oracle's own blast door, asserted from inside it.

tests/toolkit/pytest.sh runs this suite under a hard RLIMIT_AS. That is not
hygiene, it is the only thing standing between a generated mutant and the host:
run-generated.sh bounds a mutant's wall clock and nothing else, and on
2026-09-02 the mutant `queue_cleanup.py:209 break ==> continue` turned the
max-pages guard into a loop that extended a list and emitted a captured log line
every iteration. With no memory bound it consumed this 1.8 GiB host's RAM and
swap and rebooted the machine, twice, losing ~30 minutes of sweep each time.

`docker run --memory` cannot help here -- the host boots with
`cgroup_disable=memory`, so docker silently ignores it -- which is exactly why
the cap is easy to "clean up" out of pytest.sh by someone who assumes the
container already bounds it. This test is what notices.

It asserts the limit is FINITE rather than a specific number, so retuning the
cap is a one-line change while removing it is a red suite.
"""

import resource


def test_the_oracle_runs_under_a_bounded_address_space():
    soft, _hard = resource.getrlimit(resource.RLIMIT_AS)
    assert soft != resource.RLIM_INFINITY, (
        "RLIMIT_AS is unlimited: the oracle has no memory bound. A mutant that "
        "loops allocating can now take the host down instead of being scored "
        "KILLED. See the ulimit -v in tests/toolkit/pytest.sh."
    )


def test_the_bound_is_low_enough_to_matter():
    """A cap near or above host RAM (1.8 GiB) would satisfy the test above
    and protect nothing -- so the ceiling here tracks the configured cap
    (512 MiB, pytest.sh's MEM_KB default) rather than the host's, leaving
    headroom for a deliberate retune without being loose enough to let a
    near-host-RAM cap slip through unnoticed.
    """
    soft, _hard = resource.getrlimit(resource.RLIMIT_AS)
    assert soft <= 768 * 1024 ** 2, f"address-space cap is {soft} bytes, too high to bound anything"
