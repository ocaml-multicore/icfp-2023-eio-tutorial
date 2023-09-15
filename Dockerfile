FROM --platform=linux/amd64 ocaml/opam:debian-12-opam as base
RUN sudo ln -sf /usr/bin/opam-2.1 /usr/bin/opam
ENV OPAMYES="1" OPAMCONFIRMLEVEL="unsafe-yes" OPAMERRLOGLEN="0" OPAMPRECISETRACKING="1"
RUN cd ~/opam-repository && git fetch origin master && git reset --hard d8b94b939664f77f072b506a5b75f87b33e32abd && opam update
WORKDIR src
RUN sudo apt install -y libunwind-dev linux-perf

# 
# To try tsan, uncomment the following block and ALSO the block below
# Note that at time writing this doesn't work on M1/M2 macs
#
#FROM base as tsan
#RUN opam switch create 5.1.0+tsan
#COPY vendor/ocaml-git/*.opam vendor/ocaml-git/
#RUN opam pin -yn --with-version=3.13.0 vendor/ocaml-git
#COPY tutorial.opam .
#RUN opam install --deps-only -t .

FROM base as ocaml510fp
RUN opam switch create 5.1.0+fp ocaml-variants.5.1.0+options ocaml-option-fp
COPY vendor/ocaml-git/*.opam vendor/ocaml-git/
RUN opam pin -yn --with-version=3.13.0 vendor/ocaml-git
COPY tutorial.opam .
RUN opam install --switch=5.1.0+fp --deps-only -t .

#
# Also uncomment this block to try tsan
#
#COPY --from=tsan /home/opam/.opam/5.1.0+tsan /home/opam/.opam/5.1.0+tsan
#RUN sed -i 's/installed-switches: "5.1.0+fp"/installed-switches: ["5.1.0+fp" "5.1.0+tsan"]/' ../.opam/config

RUN opam install ocaml-lsp-server ocamlformat
ENTRYPOINT [ "opam", "exec", "--" ]
CMD bash

COPY . .

RUN opam exec -- make
