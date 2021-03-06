# temporary hack while ruby_deploy specs are dependent on an installed MR
unless `which macruby`.empty? || `macruby --version`.chomp != RUBY_DESCRIPTION

require File.expand_path('../../spec_helper', __FILE__)

module DeploySpecHelper
  include FileUtils

  EMBEDDED_FRAMEWORK = '@executable_path/../Frameworks/MacRuby.framework/Versions/Current/usr/lib/libmacruby.dylib'

  def deploy(args)
    ruby_exe(File.join(SOURCE_ROOT, 'bin/ruby_deploy'), :args => "'#{@app_bundle}' #{args} 2>&1")
  end

  def file(path)
    `/usr/bin/file '#{path}'`
  end

  def install_name(path)
    `/usr/bin/otool -L '#{path}'`
  end

  def resources
    File.join(@app_bundle, 'Contents', 'Resources')
  end

  def rbos
    Dir.glob("#{resources}/**/*.rbo")
  end

  def rbs
    Dir.glob("#{resources}/**/*.rb")
  end

  def binaries
    rbos + [File.join(@app_bundle, 'Contents', 'MacOS', 'Dummy')]
  end

  def framework
    File.join(@app_bundle, 'Contents', 'Frameworks', 'MacRuby.framework', 'Versions')
  end
end

describe "ruby_deploy, in general," do
  extend DeploySpecHelper

  it "checks if the given path is a valid app bundle" do
    @dir = tmp('ruby_deploy')
    @app_bundle = File.join(@dir, 'Dummy.app')
    mkdir_p @app_bundle
    deploy('--compile').should include("doesn't seem to be a valid application bundle")
    rm_rf @dir
  end
end

describe "ruby_deploy command line options:" do
  extend DeploySpecHelper

  before do
    @dir = tmp('ruby_deploy')
    mkdir_p @dir
    @app_bundle = File.join(@dir, 'Dummy.app')
    cp_r File.join(FIXTURES, 'dummy_app'), @app_bundle
    # we just need a binary file compiled in the arch for the current env
    mkdir File.join(@app_bundle, 'Contents/MacOS')
    cp File.join(SOURCE_ROOT, 'lib/irb.rbo'), File.join(@app_bundle, 'Contents/MacOS/Dummy')
  end

  after do
    rm_rf @dir
  end

  describe "the --compile option" do
    it "compiles the ruby source files in the app's Resources directory" do
      deploy('--compile')
      rbos.should_not be_empty
      rbos.each do |rbo|
        file(rbo).should include('Mach-O')
        require rbo
      end
      # check that the classes defined in the rbos actually work
      defined?(DummyModel).should == "constant"
      defined?(DummyController).should == "constant"
    end

    it "does not compile the rb_main.rb file, because this name is hardcoded in the function that starts MacRuby" do
      deploy('--compile')
      rbos.map { |f| File.basename(f) }.should_not include('rb_main.rbo')
      rbs.map { |f| File.basename(f) }.should include('rb_main.rb')
    end

    it "removes the original source files after compilation" do
      deploy('--compile')
      rbs.map { |f| File.basename(f) }.should == %w{ rb_main.rb }
    end

    it "does not change the install_name of binaries if the MacRuby framework is not embedded" do
      deploy('--compile')
      binaries.each do |bin|
        install_name(bin).should_not include(DeploySpecHelper::EMBEDDED_FRAMEWORK)
      end
    end

    it "changes the install_name of binaries to the embedded MacRuby framework" do
      mkdir_p File.join(@app_bundle, 'Contents/Frameworks/MacRuby.framework')
      deploy('--compile')
      binaries.each do |bin|
        install_name(bin).should include(DeploySpecHelper::EMBEDDED_FRAMEWORK)
      end
    end

    # TODO is it safe to use `ppc7400' here?
    it "retrieves the archs that the ruby files should be compiled for from ENV['ARCHS'] and aborts if that leaves no options" do
      before, ENV['ARCHS'] = ENV['ARCHS'], 'ppc7400'
      begin
        deploy('--compile').should =~ /Can't build for.+?ppc7400/
        $?.success?.should == false
      ensure
        ENV['ARCHS'] = before
      end
    end

    # TODO is it safe to use `ppc' here?
    it "retrieves the arch that the ruby files should be compiled for from the app binary and skips those that can't be used" do
      # copy the system ruby binary which, amongst others, contains `ppc'
      rm File.join(@app_bundle, 'Contents/MacOS/Dummy')
      cp '/usr/bin/ruby', File.join(@app_bundle, 'Contents/MacOS/Dummy')

      deploy('--compile').should =~ /Can't build for.+?ppc7400/
      $?.success?.should == true
    end
  end

  describe 'the --embed option' do
    it 'copies the framework to Contents/Frameworks' do
      deploy('--embed')
      Dir.exists?(framework).should == true
      Dir.exists?(File.join(framework, 'Current/usr/lib/ruby')).should == true
      File.exists?(File.join(framework, 'Current/usr/lib/libmacruby.1.9.2.dylib'))
    end

    it 'only copies the Current version which is not a symlink' do
      deploy('--embed')

      dirs = Dir.entries(framework) - ['.','..']
      dirs.count.should == 1
      dirs.should include('Current')

      File.symlink?(File.join(framework, 'Current')).should be_false

      rbconfig_dir = RbConfig::CONFIG['archdir'].sub(RbConfig::CONFIG['prefix'], '')
      rbconfig = File.join(framework, 'Current', 'usr', rbconfig_dir, 'rbconfig.rb')
      File.read(rbconfig).split("\n").find do |line|
        line.match /CONFIG\["INSTALL_VERSION"\]\s+=\s+"([\d\.]+)"/
      end
      $1.should == MACRUBY_VERSION
    end

    it 'does not copy headers, binaries, or documentation into the app bundle' do
      deploy('--embed')
      dirs = Dir.entries(File.join(framework, 'Current', 'usr'))
      ['bin','include','share'].each do |dir|
        dirs.should_not include(dir)
      end
      # TODO is the libmacruby-static.a file used by anyone?
    end

    # TODO is this test too naive?
    it 'embeds bridge support files when combined with --bs' do
      deploy('--embed --bs')
      bs_dir = File.join(resources, 'BridgeSupport')
      Dir.exists?(bs_dir)
      (Dir.entries(bs_dir) - ['.', '..']).should_not be_empty
    end

    it 'removes the stdlib when combined with --no-stdlib' do
      deploy('--embed --no-stdlib')
      stdlib_dir = File.join(framework, 'Current', 'usr', 'lib', 'ruby')
      Dir.exists?(stdlib_dir).should == false
    end

    # TODO --gem GEM
    # TODO make sure installed gems aren't embedded by default
    # TODO --stdlib LIB
  end

end

end
