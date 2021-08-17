
require 'digest'

module Pod
  class Config
    alias_method :ori_lockfile, :lockfile
    def lockfile
      @lockfile ||= Lockfile.from_mbox
    end

    attr_accessor :write_independent_lockfile
    def write_independent_lockfile
      if @write_independent_lockfile.nil?
        @write_independent_lockfile = true
      end
      @write_independent_lockfile
    end
  end

  class Lockfile
    def self.load_from_repos
      repos = MBox::Config.instance.current_feature.repos || []
      dev_pods = MBox::Config.instance.development_pods
      path = MBox::Config::Repo.lockfile_path
      lockfile = new({})
      lockfile.defined_in_file = path

      current_feature = ::MBox::Config.instance.current_feature
      mbox_repos = current_feature.current_cocoapods_container_repos

      mbox_repos.each do |repo|
        next if repo.podlock_path.nil? || !repo.podlock_path.exist?
        hash = YAMLHelper.load_file(repo.podlock_path)
        unless hash && hash.is_a?(Hash)
          raise Informative, "Invalid Lockfile in `#{path}`"
        end
        if !dev_pods.blank? && !hash['PODS'].blank?
          hash['PODS'].delete_if do |pod|
            pod = pod.keys.first unless pod.is_a?(String)
            name, _ = Spec.name_and_version_from_string(pod)
            name = Specification.root_name(name)
            dev_pods.key?(name)
          end
        end
        hash.each do |key, value|
          if value.is_a? Array
            lockfile.internal_data[key] = (lockfile.internal_data[key] || []).concat(value).uniq
          elsif value.is_a? Hash
            lockfile.internal_data[key] ||= {}
            lockfile.internal_data[key].merge!(value)
          end
        end
      end
      lockfile
    end

    def self.from_mbox
      load_from_repos
    end

    def checksum_data_for_mbox
      checksum_data
    end

  end

  class Installer
    module MBoxLockFile
      # 为每个独立项目的 Podfile.lock 更新一遍，方便提交更新的依赖
      def write_lockfiles
        super
        return unless config.write_independent_lockfile
        external_source_pods = analysis_result.podfile_dependency_cache.podfile_dependencies.select(&:external_source).map(&:root_name).uniq
        checkout_options = sandbox.checkout_sources.select { |root_name, _| external_source_pods.include? root_name }

        current_feature = ::MBox::Config.instance.current_feature
        mbox_repos = current_feature.current_cocoapods_container_repos

        mbox_repos.each do |repo|
          next if repo.podfile_path.blank? || repo.podlock_path.blank?
          path = repo.podfile_path
          UI.message "- Writing independent Lockfile in #{path.dirname + "Podfile.lock"}" do
            specs_by_workspace = []
            root = repo.path.realpath.relative_path_from(MBox::Config.instance.project_root.realpath).to_s
            analysis_result.specs_by_target.each do |target_definition, specs|
              next if specs.empty?
              if target_definition.user_project_path.start_with?(root + File::SEPARATOR)
                specs_by_workspace += specs
              end
            end

            pod_names_by_workspace = specs_by_workspace.map { |spec| Specification.root_name(spec.name) }.uniq

            checkout_options_by_workspace = checkout_options.select { |root_name, _| pod_names_by_workspace.include?(root_name) }

            spec_sources_by_workspace = {}
            analysis_result.specs_by_source.each do |source, specs|
              filtered = specs.select { |spec| pod_names_by_workspace.include?(Specification.root_name(spec.name)) }
              spec_sources_by_workspace[source] = filtered unless filtered.blank?
            end

            config.with_changes({:silent => true}) do
              Dir.chdir(path.dirname) do
                podfile = Podfile.from_file(path)
                lockfile = Lockfile.generate(podfile, specs_by_workspace, checkout_options_by_workspace, spec_sources_by_workspace)
                lockfile_path = path.dirname + 'Podfile.lock'
                ori_lockfile = Lockfile.from_file(lockfile_path)
                if ori_lockfile
                  override_lockfile(ori_lockfile, lockfile)
                  lockfile.write_to_disk(path.dirname + "Podfile.lock")
                end
              end
            end
          end
        end
      end

      def override_lockfile(ori_lockfile, lockfile)
        dev_pods = MBox::Config.instance.development_pods

        ## COCOAPODS
        lockfile.internal_data['COCOAPODS'] = ori_lockfile.internal_data['COCOAPODS']

        ## PODS
        lockfile.internal_data['PODS'].map! do |pod|
          name = pod.is_a?(String) ? pod : pod.keys.first
          name, version = Specification.name_and_version_from_string(name)
          if dev_pods.key?(Specification.root_name(name))
            ori_lockfile.internal_data['PODS'].find { |ori_pod|
              ori_name = ori_pod.is_a?(String) ? ori_pod : ori_pod.keys.first
              ori_name, _ = Specification.name_and_version_from_string(ori_name)
              ori_name == name
            }
          else
            pod
          end
        end.compact!

        ## DEPENDENCIES
        (lockfile.internal_data['DEPENDENCIES'] || []).map! do |string|
          dp = Dependency.from_string(string)
          if dev_pods.key?(dp.root_name)
            ori_dp = ori_lockfile.dependencies.find{ |ori_dp| ori_dp.name == dp.name }
            ori_dp ? ori_dp.to_s : nil
          else
            string
          end
        end.compact!

        ## EXTERNAL SOURCES
        ori_external_sources = ori_lockfile.internal_data['EXTERNAL SOURCES']
        lockfile.internal_data['EXTERNAL SOURCES'] = lockfile.internal_data['EXTERNAL SOURCES'].map do |name, source|
          if dev_pods.key?(Specification.root_name(name))
            source = ori_external_sources ? ori_external_sources[name] : nil
          end
          source.nil? ? nil : [name, source]
        end.compact.to_h

        # CHECKOUT OPTIONS
        ori_checkout_options = ori_lockfile.internal_data['CHECKOUT OPTIONS']
        lockfile.internal_data['CHECKOUT OPTIONS'] = lockfile.internal_data['CHECKOUT OPTIONS'].map do |name, checkout|
          if dev_pods.key?(name)
            checkout = ori_checkout_options ? ori_checkout_options[name] : nil
          end
          checkout.nil? ? nil : [name, checkout]
        end.compact.to_h

        ## SPEC CHECKSUMS
        ori_spec_checksums = ori_lockfile.internal_data['SPEC CHECKSUMS']
        lockfile.internal_data['SPEC CHECKSUMS'] = lockfile.internal_data['SPEC CHECKSUMS'].map do |name, checksum|
          if dev_pods.key?(name)
            checksum = ori_spec_checksums ? ori_spec_checksums[name] : nil
          end
          checksum.nil? ? nil : [name, checksum]
        end.compact.to_h

        ## SPEC REPOS
        new_spec_repos = lockfile.internal_data['SPEC REPOS']
        dev_pods.each do |dp, spec_path|
          dev_repo = nil
          repos = ori_lockfile.internal_data['SPEC REPOS']
          repos.each do |repo, specs|
            if specs.include?(dp)
              dev_repo = repo
              break
            end
          end if repos
          if dev_repo
            (new_spec_repos[dev_repo] ||= []) << dp
          end
        end
        lockfile.internal_data['SPEC REPOS'] = new_spec_repos
      end
    end

    prepend MBoxLockFile
  end
end
