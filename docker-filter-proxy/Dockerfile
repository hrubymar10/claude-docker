FROM golang:alpine AS build
COPY main.go go.mod /src/
RUN cd /src && CGO_ENABLED=0 go build -o /docker-filter-proxy main.go

FROM scratch
COPY --from=build /docker-filter-proxy /docker-filter-proxy
ENTRYPOINT ["/docker-filter-proxy"]
