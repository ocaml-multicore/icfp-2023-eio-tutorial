all:
	dune build

test:
	dune exec -- ./client/main.exe

deps:
	opam install --deps-only -t .

docker-image:
	docker build -t icfp .
