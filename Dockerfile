FROM ocaml/opam:debian-12-ocaml-5.1
RUN sudo ln -sf /usr/bin/opam-2.1 /usr/bin/opam
RUN cd ~/opam-repository && git fetch origin master && git reset --hard 7dbbdf38edcb4e6e73461f0e7bb2ada6c9314c2f && opam update
WORKDIR src
COPY vendor vendor
RUN opam pin -yn --with-version=3.13.0 vendor/ocaml-git
COPY tutorial.opam .
RUN opam install --deps-only -t .
COPY . .
RUN opam exec -- make
