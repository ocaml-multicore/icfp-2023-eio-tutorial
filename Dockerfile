FROM --platform=linux/amd64 ocaml/opam:debian-12-ocaml-5.1 as base
RUN sudo ln -sf /usr/bin/opam-2.1 /usr/bin/opam
RUN cd ~/opam-repository && git fetch origin master && git reset --hard 7dbbdf38edcb4e6e73461f0e7bb2ada6c9314c2f && opam update
WORKDIR src
COPY vendor vendor
RUN sudo apt install -y libunwind-dev linux-perf
COPY tutorial.opam .

FROM base as tsan
RUN opam switch create tsan ocaml-option-tsan
RUN opam pin add ocaml-compiler-libs.v0.12.5 git+https://github.com/art-w/ocaml-compiler-libs.git\#ocaml-5.2-trunk
RUN opam pin add ppxlib.0.31.0 git+https://github.com/panglesd/ppxlib.git\#trunk-support-502
RUN opam pin -yn --with-version=3.13.0 vendor/ocaml-git
RUN opam install --switch=tsan --deps-only -t .

FROM base as ocaml510fp
RUN opam switch create 5.1.0~rc2+fp ocaml-variants.5.1.0~rc2+options ocaml-option-fp
RUN opam pin -yn --with-version=3.13.0 vendor/ocaml-git
RUN opam install --switch=5.1.0~rc2+fp --deps-only -t .

COPY --from=tsan /home/opam/.opam/tsan /home/opam/.opam/tsan
RUN sed -i s/\\\"5.1\\\"\\\]/\\\"5.1\\\"\\\ \\\"tsan\\\"\\\]/ ../.opam/config

RUN opam install ocaml-lsp-server ocamlformat

COPY . .

RUN opam exec -- make

