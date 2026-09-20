# frozen_string_literal: true

require "optparse"

module LocalModelEvaluation
  module RunpodBootstrapOptions
    module_function

    def validate!(opts, remaining_args)
      raise OptionParser::MissingArgument, "--workers" unless opts[:workers]
      raise OptionParser::MissingArgument, "--model" if opts[:models].empty?
      if opts[:pull_timeout_seconds] <= 0
        raise OptionParser::InvalidArgument, "--pull-timeout-seconds must be a positive integer"
      end
      if opts[:clean] && opts[:reuse_existing]
        raise OptionParser::InvalidArgument, "--clean cannot be combined with --reuse-existing"
      end
      if opts[:copy_to_workspace] && opts[:reuse_existing]
        raise OptionParser::InvalidArgument, "--copy-to-workspace cannot be combined with --reuse-existing"
      end
      if opts[:copy_from_shared_store]
        unless opts[:copy_from_shared_store].start_with?("/")
          raise OptionParser::InvalidArgument, "--copy-from-shared-store must be an absolute remote path"
        end
        if opts[:reuse_existing]
          raise OptionParser::InvalidArgument, "--copy-from-shared-store cannot be combined with --reuse-existing"
        end
        if opts[:copy_to_workspace]
          raise OptionParser::InvalidArgument, "--copy-from-shared-store cannot be combined with --copy-to-workspace"
        end
        if opts[:keep_root_models]
          raise OptionParser::InvalidArgument, "--copy-from-shared-store cannot be combined with --keep-root-models"
        end
        if opts[:clean]
          raise OptionParser::InvalidArgument, "--copy-from-shared-store cannot be combined with --clean"
        end
        if opts[:models].length != 1
          raise OptionParser::InvalidArgument, "--copy-from-shared-store requires exactly one --model"
        end
      end
      if opts[:copy_to_workspace] && opts[:keep_root_models]
        raise OptionParser::InvalidArgument, "--copy-to-workspace cannot be combined with --keep-root-models"
      end
      if opts[:keep_root_models] && opts[:reuse_existing]
        raise OptionParser::InvalidArgument, "--keep-root-models cannot be combined with --reuse-existing"
      end
      if opts[:keep_root_models] && opts[:models].length != 1
        raise OptionParser::InvalidArgument, "--keep-root-models requires exactly one --model"
      end
      if !opts[:reuse_existing] && !opts[:copy_to_workspace] && opts[:models].length != 1
        raise OptionParser::InvalidArgument,
              "fresh root-storage bootstrap requires exactly one --model; use --copy-to-workspace for multiple models"
      end
      raise OptionParser::InvalidArgument, "unexpected arguments: #{remaining_args.join(' ')}" unless remaining_args.empty?

      true
    end
  end
end
