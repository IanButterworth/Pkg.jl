# This file is a part of Julia. License is MIT: https://julialang.org/license

module GitTools

using ..Pkg
using ..MiniProgressBars
import ..can_fancyprint, ..printpkgstyle, ..stdout_f
using SHA
import Base: SHA1
import LibGit2
using Printf

use_cli_git() = Base.get_bool_env("JULIA_PKG_USE_CLI_GIT", false)
const RESOLVING_DELTAS_HEADER = "Resolving Deltas:"

function transfer_progress(progress::Ptr{LibGit2.TransferProgress}, p::Any)
    progress = unsafe_load(progress)
    @assert haskey(p, :transfer_progress)
    bar = p[:transfer_progress]
    @assert typeof(bar) == MiniProgressBar
    if progress.total_deltas != 0
        if bar.header != RESOLVING_DELTAS_HEADER
            bar.header = RESOLVING_DELTAS_HEADER
            bar.prev = 0
        end
        bar.max = progress.total_deltas
        bar.current = progress.indexed_deltas
    else
        bar.max = progress.total_objects
        bar.current = progress.received_objects
    end
    show_progress(stdout_f(), bar)
    return Cint(0)
end

const GIT_REGEX =
    r"^(?:(?<proto>git|ssh|https)://)?(?:[\w\.\+\-:]+@)?(?<hostname>.+?)(?(<proto>)/|:)(?<path>.+?)(?:\.git)?$"
const GIT_PROTOCOLS = Dict{String, Union{Nothing, String}}()
const GIT_USERS = Dict{String, Union{Nothing, String}}()

@deprecate setprotocol!(proto::Union{Nothing, AbstractString}) setprotocol!(protocol = proto) false

function setprotocol!(;
        domain::AbstractString = "github.com",
        protocol::Union{Nothing, AbstractString} = nothing,
        user::Union{Nothing, AbstractString} = (protocol == "ssh" ? "git" : nothing)
    )
    domain = lowercase(domain)
    GIT_PROTOCOLS[domain] = protocol
    return GIT_USERS[domain] = user
end

function normalize_url(url::AbstractString)
    # LibGit2 is fussy about trailing slash. Make sure there is none.
    url = rstrip(url, '/')
    m = match(GIT_REGEX, url)
    m === nothing && return url

    host = m[:hostname]
    path = "$(m[:path]).git"

    proto = get(GIT_PROTOCOLS, lowercase(host), nothing)

    return if proto === nothing
        url
    else
        user = get(GIT_USERS, lowercase(host), nothing)
        user = user === nothing ? "" : "$user@"

        "$proto://$user$host/$path"
    end
end

function ensure_clone(io::IO, target_path, url; kwargs...)
    if ispath(target_path)
        return LibGit2.GitRepo(target_path)
    else
        return GitTools.clone(io, url, target_path; kwargs...)
    end
end

function checkout_tree_to_path(repo::LibGit2.GitRepo, tree::LibGit2.GitObject, path::String)
    return GC.@preserve path begin
        opts = LibGit2.CheckoutOptions(
            checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
            target_directory = Base.unsafe_convert(Cstring, path)
        )
        LibGit2.checkout_tree(repo, tree, options = opts)
    end
end

function clone(io::IO, url, source_path; header = nothing, credentials = nothing, isbare = false, kwargs...)
    url = String(url)::String
    source_path = String(source_path)::String
    @assert !isdir(source_path) || isempty(readdir(source_path))
    url = normalize_url(url)
    printpkgstyle(io, :Cloning, header === nothing ? "git-repo `$url`" : header)
    bar = MiniProgressBar(header = "Cloning:", color = Base.info_color())
    fancyprint = can_fancyprint(io)
    fancyprint && start_progress(io, bar)
    if credentials === nothing
        credentials = LibGit2.CachedCredentials()
    end
    return try
        if use_cli_git()
            args = ["--quiet", url, source_path]
            isbare && pushfirst!(args, "--bare")
            cmd = `git clone $args`
            try
                run(pipeline(cmd; stdout = devnull))
            catch err
                Pkg.Types.pkgerror("The command $(cmd) failed, error: $err")
            end
            return LibGit2.GitRepo(source_path)
        else
            callbacks = if fancyprint
                LibGit2.Callbacks(
                    :transfer_progress => (
                        @cfunction(transfer_progress, Cint, (Ptr{LibGit2.TransferProgress}, Any)),
                        bar,
                    )
                )
            else
                LibGit2.Callbacks()
            end
            mkpath(source_path)
            return LibGit2.clone(url, source_path; callbacks, credentials, isbare, kwargs...)
        end
    catch err
        rm(source_path; force = true, recursive = true)
        err isa LibGit2.GitError || err isa InterruptException || rethrow()
        if err isa InterruptException
            Pkg.Types.pkgerror("git clone of `$url` interrupted")
        elseif (err.class == LibGit2.Error.Net && err.code == LibGit2.Error.EINVALIDSPEC) ||
                (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ENOTFOUND)
            Pkg.Types.pkgerror("git repository not found at `$(url)`")
        else
            Pkg.Types.pkgerror("failed to clone from $(url), error: $err")
        end
    finally
        Base.shred!(credentials)
        fancyprint && end_progress(io, bar)
    end
end

function geturl(repo)
    return LibGit2.with(LibGit2.get(LibGit2.GitRemote, repo, "origin")) do remote
        LibGit2.url(remote)
    end
end

function fetch(io::IO, repo::LibGit2.GitRepo, remoteurl = nothing; header = nothing, credentials = nothing, refspecs = [""], kwargs...)
    if remoteurl === nothing
        remoteurl = geturl(repo)
    end
    fancyprint = can_fancyprint(io)
    remoteurl = normalize_url(remoteurl)
    printpkgstyle(io, :Updating, header === nothing ? "git-repo `$remoteurl`" : header)
    bar = MiniProgressBar(header = "Fetching:", color = Base.info_color())
    callbacks = if fancyprint
        LibGit2.Callbacks(
            :transfer_progress => (
                @cfunction(transfer_progress, Cint, (Ptr{LibGit2.TransferProgress}, Any)),
                bar,
            )
        )
    else
        LibGit2.Callbacks()
    end
    fancyprint && start_progress(io, bar)
    if credentials === nothing
        credentials = LibGit2.CachedCredentials()
    end
    return try
        if use_cli_git()
            let remoteurl = remoteurl
                cmd = `git -C $(LibGit2.path(repo)) fetch -q $remoteurl $(only(refspecs))`
                try
                    run(pipeline(cmd; stdout = devnull))
                catch err
                    Pkg.Types.pkgerror("The command $(cmd) failed, error: $err")
                end
            end
        else
            return LibGit2.fetch(repo; remoteurl, callbacks, credentials, refspecs, kwargs...)
        end
    catch err
        err isa LibGit2.GitError || rethrow()
        if (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ERROR)
            Pkg.Types.pkgerror("Git repository not found at '$(remoteurl)'")
        else
            Pkg.Types.pkgerror("failed to fetch from $(remoteurl), error: $err")
        end
    finally
        Base.shred!(credentials)
        fancyprint && end_progress(io, bar)
    end
end


# This code gratefully adapted from https://github.com/simonbyrne/GitX.jl
@enum GitMode mode_dir = 0o040000 mode_normal = 0o100644 mode_executable = 0o100755 mode_symlink = 0o120000 mode_submodule = 0o160000
Base.string(mode::GitMode) = string(UInt32(mode); base = 8)
Base.print(io::IO, mode::GitMode) = print(io, string(mode))

function gitmode(path::AbstractString)
    # Windows doesn't deal with executable permissions in quite the same way,
    # `stat()` gives a different answer than we actually want, so we use
    # `isexecutable()` which uses `uv_fs_access()` internally.  On other
    # platforms however, we just want to check via `stat()`.
    function isexec(p)
        @static if Sys.iswindows()
            return Sys.isexecutable(p)
        end
        return !iszero(filemode(p) & 0o100)
    end
    if islink(path)
        return mode_symlink
    elseif isdir(path)
        return mode_dir
    elseif isexec(path)
        return mode_executable
    else
        return mode_normal
    end
end

"""
    blob_hash(HashType::Type, path::AbstractString)

Calculate the git blob hash of a given path.
"""
function blob_hash(::Type{HashType}, path::AbstractString) where {HashType}
    ctx = HashType()
    if islink(path)
        datalen = length(readlink(path))
    else
        datalen = filesize(path)
    end

    # First, the header
    SHA.update!(ctx, Vector{UInt8}("blob $(datalen)\0"))

    # Next, read data in in chunks of 4KB
    buff = Vector{UInt8}(undef, 4 * 1024)

    try
        if islink(path)
            update!(ctx, Vector{UInt8}(readlink(path)))
        else
            open(path, "r") do io
                while !eof(io)
                    num_read = readbytes!(io, buff)
                    update!(ctx, buff, num_read)
                end
            end
        end
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @warn("Unable to open $(path) for hashing; git-tree-sha1 likely suspect")
    end

    # Finish it off and return the digest!
    return SHA.digest!(ctx)
end
blob_hash(path::AbstractString) = blob_hash(SHA1_CTX, path)

"""
    contains_files(root::AbstractString)

Helper function to determine whether a directory contains files; e.g. it is a
direct parent of a file or it contains some other directory that itself is a
direct parent of a file. This is used to exclude directories from tree hashing.
"""
function contains_files(path::AbstractString)
    st = lstat(path)
    ispath(st) || throw(ArgumentError("non-existent path: $(repr(path))"))
    isdir(st) || return true
    for p in readdir(path)
        contains_files(joinpath(path, p)) && return true
    end
    return false
end


"""
    tree_hash(HashType::Type, root::AbstractString)

Calculate the git tree hash of a given path.
"""
function tree_hash(::Type{HashType}, root::AbstractString; debug_out::Union{IO, Nothing} = nothing, indent::Int = 0) where {HashType}
    entries = Tuple{String, Vector{UInt8}, GitMode}[]
    for f in sort(readdir(root; join = true); by = f -> gitmode(f) == mode_dir ? f * "/" : f)
        # Skip `.git` directories
        if basename(f) == ".git"
            continue
        end

        filepath = abspath(f)
        mode = gitmode(filepath)
        if mode == mode_dir
            # If this directory contains no files, then skip it
            contains_files(filepath) || continue

            # Otherwise, hash it up!
            child_stream = nothing
            if debug_out !== nothing
                child_stream = IOBuffer()
            end
            hash = tree_hash(HashType, filepath; debug_out = child_stream, indent = indent + 1)
            if debug_out !== nothing
                indent_str = "| "^indent
                println(debug_out, "$(indent_str)+ [D] $(basename(filepath)) - $(bytes2hex(hash))")
                print(debug_out, String(take!(child_stream)))
                println(debug_out, indent_str)
            end
        else
            hash = blob_hash(HashType, filepath)
            if debug_out !== nothing
                indent_str = "| "^indent
                mode_str = mode == mode_normal ? "F" : "X"
                println(debug_out, "$(indent_str)[$(mode_str)] $(basename(filepath)) - $(bytes2hex(hash))")
            end
        end
        push!(entries, (basename(filepath), hash, mode))
    end

    content_size = 0
    for (n, h, m) in entries
        content_size += ndigits(UInt32(m); base = 8) + 1 + sizeof(n) + 1 + sizeof(h)
    end

    # Return the hash of these entries
    ctx = HashType()
    SHA.update!(ctx, Vector{UInt8}("tree $(content_size)\0"))
    for (name, hash, mode) in entries
        SHA.update!(ctx, Vector{UInt8}("$(mode) $(name)\0"))
        SHA.update!(ctx, hash)
    end
    return SHA.digest!(ctx)
end
tree_hash(root::AbstractString; debug_out::Union{IO, Nothing} = nothing) = tree_hash(SHA.SHA1_CTX, root; debug_out)

function check_valid_HEAD(repo)
    return try
        LibGit2.head(repo)
    catch err
        url = try
            geturl(repo)
        catch
            "(unknown url)"
        end
        Pkg.Types.pkgerror("invalid git HEAD in $url ($(err.msg))")
    end
end

function git_file_stream(repo::LibGit2.GitRepo, spec::String; fakeit::Bool = false)::IO
    blob = try
        LibGit2.GitBlob(repo, spec)
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
        fakeit && return devnull
    end
    iob = IOBuffer(LibGit2.content(blob))
    close(blob)
    return iob
end

end # module
