# The test environment: an Arch Linux base with the tools the suites call.
# CI builds this file, so it is the one definition of that environment.
#
#   docker build -f tests/Dockerfile -t replicant-tests .
#   docker run --rm replicant-tests
#
# The suites run as a normal user. Several checks are about what a user cannot
# do, and root can read and write anything. qmllint and omarchy-plugin-validate
# are not here: run-all.sh reports them as skipped, and they run on a machine
# with Omarchy installed.
FROM archlinux:latest

RUN pacman -Syu --noconfirm --needed git jq shellcheck diffutils which \
 && pacman -Scc --noconfirm

RUN useradd -m tester
COPY --chown=tester:tester . /home/tester/replicant
USER tester
WORKDIR /home/tester/replicant
RUN git config --global user.email tests@example.com \
 && git config --global user.name Tests

CMD ["./tests/run-all.sh"]
