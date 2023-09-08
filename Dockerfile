FROM --platform=linux/amd64 ocaml/opam:debian-12-opam as base
RUN sudo ln -sf /usr/bin/opam-2.1 /usr/bin/opam
ENV OPAMYES="1" OPAMCONFIRMLEVEL="unsafe-yes" OPAMERRLOGLEN="0" OPAMPRECISETRACKING="1"
RUN cd ~/opam-repository && git fetch origin master && git reset --hard afb1f0d6b01bb1b04cb6c8b68b30cbbbfd58c0fa && opam update
WORKDIR src
RUN sudo apt install -y libunwind-dev linux-perf

FROM base as tsan
RUN opam switch create 5.1.0~rc3+tsan
COPY vendor/ocaml-git/*.opam vendor/ocaml-git/
RUN opam pin -yn --with-version=3.13.0 vendor/ocaml-git
COPY tutorial.opam .
RUN opam install --deps-only -t .

FROM base as ocaml510fp
RUN opam switch create 5.1.0~rc3+fp ocaml-variants.5.1.0~rc3+options ocaml-option-fp
COPY vendor/ocaml-git/*.opam vendor/ocaml-git/
RUN opam pin -yn --with-version=3.13.0 vendor/ocaml-git
COPY tutorial.opam .
RUN opam install --switch=5.1.0~rc3+fp --deps-only -t .

COPY --from=tsan /home/opam/.opam/5.1.0~rc3+tsan /home/opam/.opam/5.1.0~rc3+tsan
RUN sed -i 's/installed-switches: "5.1.0~rc3+fp"/installed-switches: ["5.1.0~rc3+fp" "5.1.0~rc3+tsan"]/' ../.opam/config

RUN opam install ocaml-lsp-server ocamlformat
ENTRYPOINT [ "opam", "exec", "--" ]
CMD bash

COPY . .

RUN opam exec -- make
