class EventsController < ApplicationController
  protect_from_forgery
  before_action :authenticate_user!
  before_action -> {
    event_member(params[:id], current_user.id)
  }, only:[:show, :edit, :update]
  before_action -> {
    event_kanji(params[:id], current_user.id)
  }, only:[:destroy]

  def index
    # ログインユーザのイベント取得
    @event = Event.event_list(current_user.id)
    @current_user_id = current_user.id
  end

  def add
    @date_cnt = APPSETTINGS::MAX_DATE_CNT
    @event = Event.new
  end

  def create
    if request.post? then
      @event = Event.new event_params

      # 日付の入力チェック
      if !Decision.date_exists(params[:date_val].uniq)
        flash.now[:validates] = '日付を1つ以上選択してください'
        @date_cnt = APPSETTINGS::MAX_DATE_CNT
        render 'add'
        return
      end

      # イベント・メンバー・日程判定モデルを保存
      begin
        Event.transaction do
          # ログインユーザのイベントとして作成
          @event.user_id = current_user.id
          @event.save!
          
          # 重複削除して日程判定モデルの保存
          Decision.list_save(params[:date_val].uniq.map{|w| w.blank? ? '' :  Date.parse(w) }, @event.id, @event.user_id)
          
          # 幹事を参加メンバーに追加しておく
          @member = Member.new
          @member.event_id = @event.id
          @member.user_id = @event.user_id
          @member.save!
        end
        redirect_to action: 'show', id: @event.id
      rescue => exception
        logger.error('エラー：' + exception.message)
        @date_cnt = APPSETTINGS::MAX_DATE_CNT
        render 'add'
      end
    end
  end

  def show
    @event = Event.find(params[:id])
    # 日程
    @decisionDate = Decision.select(:day).where(event_id: @event.id).group(:day).order(:day)
    
    if current_user.id == @event.user_id then
      kanji = User.find(@event.user_id)
      
      if current_user.id.to_s == ENV['SAMPLE_USER_ID'] then
        # サンプルユーザ
        @owned_lists = []
        (1..3).each do |idx|
          list = SampleClient.new(idx, 0)
          @owned_lists.push(list)
        end
        client = SampleUser.new
      else
        # TwitterAPI使用準備
        client = twitter_configuration
        options = { count: 100 }
        # 幹事ユーザのリスト取得
        @owned_lists = client.owned_lists(kanji.nickname, options)
      end
      
      # リスト選択時は、リストユーザをメンバーに加えてから表示
      if params[:list] then
        begin
          Event.transaction do
            client.list_members(kanji.nickname, params[:list]).each do |list|
              @user = User.find_for_member(list)
              if !Member.event_id(@event.id).user_id(@user.id).exists?
                # まだメンバーでないユーザがいたら、メンバーを追加する
                @member = Member.new
                @member.event_id = @event.id
                @member.user_id = @user.id
                @member.save!

                # 日程判定モデルの保存
                Decision.list_save(@decisionDate.map(&:day), @event.id, @user.id)
              end
            end
          end
        rescue => exception
          # エラーメッセージ
          flash.now[:validates] = 'メンバーの追加に失敗しました'
          logger.error('エラー：' + exception.message)
        end
      end
    end

    # ※以下2つのは必ず同じ並び順で取得すること
    # メンバー
    @member = Member.where(event_id: @event.id).order(:id)
    # 日別人別評価
    @decisionUser = Decision.decision_order_member(@event.id)

    # 可否ごとの件数をrelationで取得
    @decisionDateSum = Decision.decision_date_sum(@event.id)
    # ログイン中のユーザID(User)
    @current_user_id = current_user.id
    # リストボックスの選択肢
    @proprieties_for_options = Decision.proprieties
  rescue Twitter::Error::TooManyRequests => error
    # Twitterのエラー
    flash[:validates] = "TwitterがAPIの利用を制限しています。少し待ってから再度実行してください。"
    redirect_to action: 'index'
  end

  # 日程調整
  def adjustment
    if request.post? then
      @event = Event.find(params[:id])
      @decisionDateUser = Decision.where(event_id: @event.id, user_id: current_user.id).order(:day)
      # 対象の日付とパラメータの個数が一致することを確認
      if params[:propriety].length == @decisionDateUser.length then
        # ログイン中ユーザの評価を更新
        params[:propriety].zip(@decisionDateUser) do |propriety, decision| 
          #Decision.find_for_save() 後で消して
          decision.propriety = propriety.to_i
          decision.save!
        end
        redirect_to action: 'show', id: params[:id]
      else
        # 値が不正ですのエラーメッセージ
      end
    end
  end

  # メンバー削除
  def member_delete
    begin
      Member.transaction do
        params[:delete_list].each do | id,chk |
          # チェックボックスにチェックがついている場合
          if chk == "1" then
            # メンバーから削除
            Member.where(event_id: params[:id], user_id: id).delete_all
            # # 日程判定から削除
            Decision.where(event_id: params[:id], user_id: id).delete_all
          end
        end
      end
    rescue => exception
      # 削除に失敗したエラーメッセージ
      flash[:validates] = "メンバーの削除に失敗しました"
      logger.error('エラー：' + exception.message)
    end
    redirect_to action: 'show', id: params[:id]
  end

  def edit
    @date_cnt = APPSETTINGS::MAX_DATE_CNT
    @event = Event.find(params[:id])
    # 日程
    @decisionDate = Decision.date(@event.id)
  end

  def update
    if request.patch? then
      @event = Event.find(params[:id])
      @decisionDate = Decision.date(@event.id)
      # 日付リストの取得
      date_list = params[:date_val].uniq
      params = event_params
      
      # 日付の入力チェック
      if !Decision.date_exists(date_list)
        flash.now[:validates] = '日付を1つ以上選択してください'
        @date_cnt = APPSETTINGS::MAX_DATE_CNT
        render 'edit'
        return
      end

      begin
        Event.transaction do
          # イベント情報の更新
          @event.update_attributes!(title: params[:title], url: params[:url], fee: params[:fee], detail: params[:detail])
          
          # 日程判定モデルの更新 --------------------
          # 1.現行で新にないものはデータDelete
          @decisionDate.each do |date|
            if !date_list.include?(date.day.strftime('%Y/%m/%d')) then
              Decision.where(event_id: @event.id, day: date.day.strftime('%Y/%m/%d')).delete_all
            end
          end
          # 2.新で現行にあるものは、新のリストから削除
          old_date_list = @decisionDate.map(&:day)
          old_date_list.each do |date|
            if date_list.include?(date.strftime('%Y/%m/%d')) then
              date_list.delete(date.strftime('%Y/%m/%d'))
            end
          end
          # 3.残った新のリストをメンバー分追加
          if !date_list.empty? then
            @member = Member.where(event_id: @event.id).order(:id)
            @member.each do |member|
              # 日程判定モデルの保存
              Decision.list_save(date_list.map{|w| w.blank? ? '' :  Date.parse(w) }, @event.id, member.user_id)
            end
          end
          # -------------------------------------
        end
        redirect_to action: 'show', id: @event.id
      rescue => exception
        # エラーメッセージ
        flash[:validates] = "イベント情報の更新に失敗しました"
        logger.error('エラー：' + exception.message)
        # エラー処理
        redirect_to action: 'edit', id: @event.id
      end
    end
  end

  def destroy
    Event.find(params[:id]).destroy
    flash[:success] = "イベントを削除しました"
    redirect_to action: 'index'
  end

  private
  def event_params
    params.require(:event).permit(:title, :url, :fee, :detail, date_val: [])
  end

  def twitter_configuration
    return Twitter::REST::Client.new do |config|
      config.consumer_key        = Rails.application.credentials.twitter[:twitter_api_key]
      config.consumer_secret     = Rails.application.credentials.twitter[:twitter_api_secret]
      config.access_token        = Rails.application.credentials.twitter[:twitter_access_key]
      config.access_token_secret = Rails.application.credentials.twitter[:twitter_access_secret]
    end
  end
end
